# frozen_string_literal: true

module SolidusNumeral
  # Voids a canceled order on the Numeral ledger, triggered by
  # :order_canceled.
  #
  # Refund-first lifecycle (never DELETE /transactions here): a full refund
  # when nothing has been refunded yet; otherwise a partial refund of the
  # remaining headroom (Numeral rejects a full refund once headroom is
  # partially consumed). A current-dated refund lands in the open filing
  # period, which is correct even when the sale was already filed - deleting
  # the transaction would silently rewrite a filed period.
  class CancelOrderJob < ApplicationJob
    def perform(order)
      return unless numeral_enabled?

      OrderTransaction.with_locked_row(order, create: true) do |row|
        if row.voided?
          # Already voided; nothing to do.
        elsif row.committed?
          void(order, row)
        else
          # Nothing was committed to Numeral, but a CommitTransactionJob may
          # still be queued or retrying - mark the row voided so a late
          # commit is durably blocked (skip-and-forget would let it file the
          # canceled order).
          row.update!(state: "voided")
          skip(order, "order #{order.number} was never committed to " \
            "Numeral; local row marked voided to block a late commit")
        end
      end
    end

    private

    def void(order, row)
      # Server truth first: if a previous attempt's full refund landed but the
      # response was lost, re-sending it is rejected ("Refund cannot be
      # greater than the original amount") and this job would fail forever.
      # After reconciling, the remaining-headroom math below sees the refund
      # and this retry degrades to marking the row voided (or refunding only
      # what genuinely remains). A reconciliation failure raises and retries.
      row.reconcile_refunds_from_server!(api)

      refunded = row.refunded_snapshot

      if refunded.blank?
        refund = api.create_refund(
          transaction_id: row.numeral_transaction_id,
          type: "full"
        )
        mark_voided(order, row, refund_id: refund["id"], line_items: nil)
        return
      end

      # Partial refunds already recorded: refund whatever headroom remains.
      line_items = RefundMath.remaining_refund_lines(
        committed: row.committed_snapshot,
        refunded: refunded
      )

      if line_items.empty?
        # Everything was already refunded - the transaction is effectively
        # voided; just record the state.
        mark_voided(order, row, refund_id: nil, line_items: nil)
      else
        refund = api.create_refund(
          transaction_id: row.numeral_transaction_id,
          type: "partial",
          line_items: line_items
        )
        mark_voided(order, row, refund_id: refund["id"], line_items: line_items)
      end
    rescue ApiError => exception
      SyncLog.record(
        order: order, action: "void", status: :error,
        error_message: "#{exception.error_code}: #{exception.message}"
      )
      raise
    end

    def mark_voided(order, row, refund_id:, line_items:)
      row.record_refund_lines!(line_items) if line_items
      row.update!(state: "voided")

      SyncLog.record(
        order: order, action: "void", status: :success, numeral_id: refund_id
      )
    end

    def skip(order, message)
      SyncLog.record(
        order: order, action: "void", status: :error,
        error_message: "skipped: #{message}"
      )
    end
  end
end
