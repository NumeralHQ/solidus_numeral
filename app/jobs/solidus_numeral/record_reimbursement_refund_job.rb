# frozen_string_literal: true

module SolidusNumeral
  # Records an RMA reimbursement as a partial refund on the Numeral ledger
  # (POST /tax/refunds type=partial), triggered by :reimbursement_reimbursed.
  #
  # Return items are grouped back to their original line item through their
  # inventory units, and every refund line is capped against the committed
  # snapshot's remaining headroom (see RefundMath) so per-unit rounding drift
  # can never trip Numeral's over-refund guard.
  class RecordReimbursementRefundJob < ApplicationJob
    retry_on PendingTransactionError, wait: 1.minute, attempts: 10

    def perform(reimbursement)
      return unless numeral_enabled?

      order = reimbursement.order

      OrderTransaction.with_locked_row(order) do |row|
        if row&.voided?
          # Never refund a voided transaction: Numeral does not reject it and
          # the result would be an orphaned refund in the filing data.
          skip(order, "order #{order.number} is already voided in Numeral")
        elsif row&.committed?
          record_refund(order, row, reimbursement)
        elsif commit_pending?(order)
          # The commit job is queued or retrying; retry rather than drop the
          # refund - a terminal skip here would silently under-report.
          raise PendingTransactionError,
            "order #{order.number} has no committed Numeral transaction yet"
        else
          skip(order, "order #{order&.number} was never committed to Numeral")
        end
      end
    end

    private

    def record_refund(order, row, reimbursement)
      # Server truth first: if a previous attempt's POST landed but the
      # response was lost, the local snapshot is stale and re-sending would
      # double-report the refund (Numeral has no refund idempotency key).
      # After reconciling, capping turns this retry into a no-op or the
      # correct remainder. A reconciliation failure raises and retries.
      row.reconcile_refunds_from_server!(api)

      requested = RefundParams.reimbursement_requested_lines(
        reimbursement,
        tax_included: row.tax_included_in_amount?
      )

      line_items = RefundMath.cap_refund_lines(
        requested: requested,
        committed: row.committed_snapshot,
        refunded: row.refunded_snapshot
      )

      if line_items.empty?
        skip(order, "reimbursement #{reimbursement.number} has no refundable amounts " \
          "(already refunded, unmatched lines, or zero headroom)")
        return
      end

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
