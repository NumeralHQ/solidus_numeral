# frozen_string_literal: true

module SolidusNumeral
  # Reports a short-ship (partial cancellation) as a delta partial refund,
  # triggered by :order_short_shipped.
  #
  # The order's CURRENT per-line amounts (encoded exactly like the committed
  # calculation, per-unit rounding included) are diffed against the remaining
  # committed amounts (committed snapshot minus refunds already recorded); any
  # decrease is refunded with tax prorated at the committed effective rate.
  # Running the same diff twice is a no-op, so the job is idempotent.
  class ShortShipRefundJob < ApplicationJob
    retry_on PendingTransactionError, wait: 1.minute, attempts: 10

    def perform(order)
      return unless numeral_enabled?

      OrderTransaction.with_locked_row(order) do |row|
        if row&.voided?
          skip(order, "order #{order.number} is already voided in Numeral")
        elsif row&.committed?
          refund_deltas(order, row)
        elsif commit_pending?(order)
          # The commit job is queued or retrying; retry rather than drop the
          # delta - a terminal skip here would silently under-report.
          raise PendingTransactionError,
            "order #{order.number} has no committed Numeral transaction yet"
        else
          skip(order, "order #{order&.number} was never committed to Numeral")
        end
      end
    end

    private

    def refund_deltas(order, row)
      # Server truth first: if a previous attempt's POST landed but the
      # response was lost, the local snapshot is stale and re-diffing against
      # it would re-send the same delta (Numeral has no refund idempotency
      # key). A reconciliation failure raises and retries.
      row.reconcile_refunds_from_server!(api)

      deltas = RefundMath.short_ship_deltas(
        committed: row.committed_snapshot,
        refunded: row.refunded_snapshot,
        current: RefundParams.current_order_lines(order)
      )

      line_items = RefundMath.cap_refund_lines(
        requested: deltas,
        committed: row.committed_snapshot,
        refunded: row.refunded_snapshot
      )
      return if line_items.empty?

      refund = api.create_refund(
        transaction_id: row.numeral_transaction_id,
        type: "partial",
        line_items: line_items
      )

      row.record_refund_lines!(line_items)

      SyncLog.record(
        order: order, action: "refund", status: :success, numeral_id: refund["id"]
      )
    rescue ApiError => exception
      SyncLog.record(
        order: order, action: "refund", status: :error,
        error_message: "#{exception.error_code}: #{exception.message}"
      )
      raise
    end

    def skip(order, message)
      SyncLog.record(
        order: order, action: "refund", status: :error,
        error_message: "skipped: #{message}"
      )
    end
  end
end
