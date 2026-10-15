# frozen_string_literal: true

require "omnes"

module SolidusNumeral
  # RMA reimbursements -> partial refunds on the Numeral ledger.
  class ReimbursementSubscriber
    include Omnes::Subscriber

    handle :reimbursement_reimbursed, with: :record_refund

    def record_refund(event)
      return unless SolidusNumeral.config.enabled

      SolidusNumeral::RecordReimbursementRefundJob.perform_later(
        event.payload[:reimbursement]
      )
    end
  end
end
