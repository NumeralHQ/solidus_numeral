# frozen_string_literal: true

module SolidusNumeral
  # Raised (and retried via `retry_on`) when a refund-side job runs before
  # the order's purchase transaction has been committed to Numeral - the
  # refund must wait for CommitTransactionJob rather than be dropped.
  class PendingTransactionError < StandardError; end

  class ApplicationJob < ActiveJob::Base
    queue_as :default

    # An order can be purged before a queued job runs; nothing to do then.
    discard_on ActiveJob::DeserializationError

    private

    # Refund-side lifecycle jobs must wait for the commit when it is still in
    # flight, but skip terminally when no commit will ever come: an order
    # that never completed has no CommitTransactionJob queued, and a canceled
    # order's pending row is (or will be) marked voided instead of committed.
    def commit_pending?(order)
      order.completed_at.present? && !order.canceled?
    end

    def numeral_enabled?
      SolidusNumeral.config.enabled && SolidusNumeral.config.api_key.present?
    end

    def api
      @api ||= SolidusNumeral.api_client
    end

    def logger
      SolidusNumeral.config.logger
    end
  end
end
