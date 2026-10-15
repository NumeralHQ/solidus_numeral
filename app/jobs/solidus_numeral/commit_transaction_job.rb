# frozen_string_literal: true

module SolidusNumeral
  # Commits a completed order to Numeral's transaction ledger
  # (POST /tax/transactions), triggered by the :order_finalized event.
  #
  # Idempotency, three layers:
  # 1. Local: skipped when the OrderTransaction row is already committed (row
  #    locked for the duration, so concurrent jobs serialize).
  # 2. Numeral rejects a second transaction per calculation_id.
  # 3. Numeral rejects a duplicate reference_order_id; that error (e.g. after
  #    a timeout on a previous attempt) is recovered by looking the existing
  #    transaction up via GET /tax/transactions?reference_order_id=... and
  #    adopting it.
  class CommitTransactionJob < ApplicationJob
    # Safety margin against committing with a calculation expiring "right now".
    EXPIRY_MARGIN_SECONDS = 60

    def perform(order)
      return unless numeral_enabled?
      return unless order.completed_at

      OrderTransaction.with_locked_row(order, create: true) do |row|
        next if row.committed? || row.voided?

        if order.canceled?
          # A cancellation raced ahead of this commit (CancelOrderJob marks
          # pending rows voided, but this guards the window before it runs).
          # Committing now would file a canceled order.
          row.update!(state: "voided")
          SyncLog.record(
            order: order, action: "commit", status: :error,
            error_message: "skipped: order #{order.number} was canceled " \
              "before commit; local row marked voided"
          )
          next
        end

        commit(order, row)
      end
    end

    private

    def commit(order, row)
      calculation = usable_calculation(order)
      create_transaction(order, row, calculation, retry_on_expiry: true)
    rescue ApiError => exception
      SyncLog.record(
        order: order, action: "commit", status: :error,
        error_message: "#{exception.error_code}: #{exception.message}"
      )
      raise
    end

    def create_transaction(order, row, calculation, retry_on_expiry:)
      transaction = api.create_transaction(
        calculation_id: calculation.fetch("id"),
        reference_order_id: order.number,
        transaction_processed_at: order.completed_at.to_i,
        metadata: { "solidus_order_number" => order.number.to_s }
      )

      mark_committed(
        order,
        row,
        transaction_id: transaction["id"],
        calculation_id: calculation.fetch("id"),
        snapshot: snapshot_from_line_items(
          calculation["line_items"],
          tax_included: calculation["tax_included_in_amount"] ? true : false
        )
      )
    rescue ApiError => exception
      if exception.calculation_expired? && retry_on_expiry
        # The cart outlived the 24h calculation validity; re-quote and retry
        # once (fresh calculations cannot be expired).
        create_transaction(order, row, fresh_calculation(order), retry_on_expiry: false)
      elsif exception.duplicate_reference_order_id? || exception.transaction_already_exists?
        adopt_existing_transaction(order, row)
      else
        raise
      end
    end

    # Reuses the checkout-time calculation when it is still fresh and still
    # matches the order (any drift in lines/address/discounts changes the
    # request payload); otherwise runs a new calculation.
    def usable_calculation(order)
      payload = ApiParams.order_params(order)
      entry = CalculationCache.read_latest_for_order(order)

      if entry &&
          entry["request"] == payload &&
          calculation_fresh?(entry["response"], order)
        entry.fetch("response")
      else
        api.create_calculation(payload)
      end
    end

    def fresh_calculation(order)
      api.create_calculation(ApiParams.order_params(order))
    end

    def calculation_fresh?(response, order)
      expires_at = response["expires_at"].to_i
      expires_at.positive? &&
        expires_at > (order.completed_at.to_i + EXPIRY_MARGIN_SECONDS)
    end

    # Another process (or an earlier attempt whose response was lost) already
    # committed this order: adopt the existing Numeral transaction.
    def adopt_existing_transaction(order, row)
      transactions = Array(
        api.get_transactions(reference_order_id: order.number)["transactions"]
      )
      existing = transactions.find { |tx| tx["transaction_type"] == "PURCHASE" }

      unless existing
        raise ApiError.new(
          "Numeral reported a duplicate transaction for order #{order.number} " \
          "but none was found by reference_order_id",
          status: 404
        )
      end

      # GET /transactions carries no tax_included_in_amount flag, so derive it
      # the same way the original (lost) commit's payload did - the adopted
      # transaction was created from an identical ApiParams payload.
      mark_committed(
        order,
        row,
        transaction_id: existing["id"],
        calculation_id: existing["calculation_id"],
        snapshot: snapshot_from_line_items(
          existing["line_items"],
          tax_included: ApiParams.tax_included_in_amount?(order)
        )
      )
    end

    def mark_committed(order, row, transaction_id:, calculation_id:, snapshot:)
      row.update!(
        state: "committed",
        numeral_transaction_id: transaction_id,
        numeral_calculation_id: calculation_id,
        committed_line_items: snapshot,
        refunded_line_items: row.refunded_snapshot
      )

      SyncLog.record(
        order: order, action: "commit", status: :success, numeral_id: transaction_id
      )
    end

    # reference_line_item_id => {"amount_excluding_tax",
    # "amount_including_tax", "tax_amount", "quantity",
    # "tax_included_in_amount"}, from calculation (or transaction) response
    # line items. `tax_included` records which amount later refunds are
    # denominated in and capped against: Numeral caps refunds at
    # amount_including_tax (gross) for tax-inclusive purchases and at
    # amount_excluding_tax (net) otherwise (see RefundMath).
    def snapshot_from_line_items(line_items, tax_included:)
      Array(line_items).each_with_object({}) do |line, snapshot|
        reference_id = line.dig("product", "reference_line_item_id")
        next unless reference_id

        snapshot[reference_id] = {
          "amount_excluding_tax" => line["amount_excluding_tax"].to_i,
          "amount_including_tax" => line["amount_including_tax"].to_i,
          "tax_amount" => line["tax_amount"].to_i,
          "quantity" => line["quantity"].to_i,
          "tax_included_in_amount" => tax_included,
        }
      end
    end
  end
end
