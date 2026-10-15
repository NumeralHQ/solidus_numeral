# frozen_string_literal: true

require "omnes"

module SolidusNumeral
  # Order lifecycle -> Numeral ledger, always via background jobs (never
  # inline in state-machine transitions).
  #
  # `:order_finalized` is used for the commit (rather than solidus_taxjar's
  # `:order_recalculated` + delayed-job workaround): it is published by
  # Spree::Order#finalize after adjustments are finalized and totals
  # persisted, so no artificial delay is needed.
  class OrderSubscriber
    include Omnes::Subscriber

    handle :order_finalized, with: :commit_transaction
    handle :order_canceled, with: :cancel_order
    handle :order_short_shipped, with: :short_ship

    def commit_transaction(event)
      return unless SolidusNumeral.config.enabled

      SolidusNumeral::CommitTransactionJob.perform_later(event.payload[:order])
    end

    def cancel_order(event)
      return unless SolidusNumeral.config.enabled

      SolidusNumeral::CancelOrderJob.perform_later(event.payload[:order])
    end

    def short_ship(event)
      return unless SolidusNumeral.config.enabled

      SolidusNumeral::ShortShipRefundJob.perform_later(event.payload[:order])
    end
  end
end
