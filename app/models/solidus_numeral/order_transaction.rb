# frozen_string_literal: true

module SolidusNumeral
  # Local ledger row linking a Solidus order to its Numeral transaction.
  #
  # - `committed_line_items` snapshots the calculation response the
  #   transaction was committed from (reference_line_item_id =>
  #   {"amount_excluding_tax", "amount_including_tax", "tax_amount",
  #   "quantity", "tax_included_in_amount"} in minor units). Refund capping is
  #   computed against this snapshot, never against Solidus's own totals
  #   (per-unit rounding drift).
  # - `refunded_line_items` accumulates refunds already sent to Numeral
  #   (reference_line_item_id => {"sales_amount_refunded", "tax_amount_refunded"},
  #   both negative cumulative minor units). It is overwritten from server
  #   truth before every refund POST (see #reconcile_refunds_from_server!).
  class OrderTransaction < ActiveRecord::Base
    STATES = %w[pending committed voided].freeze

    belongs_to :order, class_name: "Spree::Order"

    validates :state, inclusion: { in: STATES }

    serialize :committed_line_items, coder: JSON
    serialize :refunded_line_items, coder: JSON

    # Serializes ledger mutations per order: acquires a row lock and yields
    # the row inside a transaction. With `create: false`, yields nil (outside
    # any transaction) when no row exists so callers can skip gracefully.
    def self.with_locked_row(order, create: false)
      row = find_by(order_id: order.id)

      if row.nil? && create
        row = begin
          create!(order_id: order.id)
        rescue ActiveRecord::RecordNotUnique
          find_by!(order_id: order.id)
        end
      end

      return yield(nil) if row.nil?

      transaction do
        row.lock!
        yield row
      end
    end

    def committed?
      state == "committed"
    end

    def voided?
      state == "voided"
    end

    def committed_snapshot
      committed_line_items || {}
    end

    def refunded_snapshot
      refunded_line_items || {}
    end

    # Whether the committed calculation priced lines tax-inclusively (VAT).
    # Refund amounts must then be denominated gross (see RefundMath).
    # Snapshots written before this field was recorded default to exclusive.
    def tax_included_in_amount?
      committed_snapshot.each_value.any? { |line| line["tax_included_in_amount"] }
    end

    def record_refund_lines!(refund_line_items)
      self.refunded_line_items = RefundMath.accumulate(
        refunded_snapshot, refund_line_items
      )
      save!
    end

    # Overwrites `refunded_line_items` with the server's view of this
    # transaction's refunds (GET /tax/transactions/:id/refunds). Numeral has
    # no refund idempotency key - only cumulative capping - so when a refund
    # POST succeeds server-side but the response is lost (e.g. a read
    # timeout), the local snapshot goes stale and a job retry would re-send
    # the same refund. Refund jobs call this inside the row lock BEFORE
    # computing refund lines, so the retry re-caps against what Numeral
    # actually recorded and becomes a no-op or the correct remainder. Server
    # truth always wins.
    #
    # Errors from the GET propagate so the job retries - a refund must never
    # be posted from state that could not be reconciled. Rows without a
    # Numeral transaction id have nothing to reconcile.
    def reconcile_refunds_from_server!(api)
      return if numeral_transaction_id.blank?

      refunds = Array(api.get_transaction_refunds(numeral_transaction_id)["refunds"])
      server = RefundMath.refunded_from_server(
        refunds: refunds,
        committed: committed_snapshot,
        default_tax_included: tax_included_in_amount?
      ) do |refund, _line|
        logger.warn(
          "[solidus_numeral] refund #{refund['id']} on transaction " \
          "#{numeral_transaction_id} has a line item without a " \
          "reference_line_item_id (created outside this gem?); it cannot be " \
          "attributed to a committed line and is ignored for refund capping"
        )
      end

      return if server == refunded_snapshot

      logger.info(
        "[solidus_numeral] refunded snapshot for order #{order_id} diverged " \
        "from Numeral (local: #{refunded_snapshot.inspect}, server: " \
        "#{server.inspect}); adopting server truth"
      )
      self.refunded_line_items = server
      save!
    end

    private

    def logger
      SolidusNumeral.config.logger
    end
  end
end
