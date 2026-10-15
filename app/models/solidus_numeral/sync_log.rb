# frozen_string_literal: true

module SolidusNumeral
  # Per-attempt log for ledger operations against Numeral, surfaced for
  # debugging silent background-job failures.
  class SyncLog < ActiveRecord::Base
    ACTIONS = %w[commit refund void customer_sync product_sync].freeze

    belongs_to :order, class_name: "Spree::Order", optional: true

    enum :status, { success: "success", error: "error" }, validate: true

    validates :action, inclusion: { in: ACTIONS }

    def self.record(action:, status:, order: nil, numeral_id: nil, error_message: nil)
      create!(
        order: order,
        action: action,
        status: status,
        numeral_id: numeral_id,
        error_message: error_message&.to_s&.first(10_000)
      )
    rescue StandardError => exception
      # Logging must never take down the operation being logged.
      SolidusNumeral.config.logger.error(
        "[solidus_numeral] failed to write sync log (#{action}/#{status}): #{exception.message}"
      )
      nil
    end
  end
end
