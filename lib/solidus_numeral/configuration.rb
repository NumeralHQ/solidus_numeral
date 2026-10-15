# frozen_string_literal: true

module SolidusNumeral
  # Plain-Ruby configuration singleton, accessed through
  # `SolidusNumeral.configure { |config| ... }` from a host-app initializer.
  class Configuration
    DEFAULT_API_BASE = "https://api.numeralhq.com"

    # Numeral secret API key ("sk_test_..." or "sk_live_..."). Which key is
    # configured determines test vs. live mode - there is no separate flag.
    attr_accessor :api_key

    # Base URL of the Numeral API. The client appends the "/tax" path prefix.
    attr_accessor :api_base

    # Kill switch. When false the calculator returns zero tax and the ledger
    # jobs no-op, without touching the API.
    attr_accessor :enabled

    # How long calculation responses are cached. Must stay below Numeral's
    # 24-hour calculation expiry.
    attr_accessor :cache_duration

    # Called with any exception raised during tax calculation. The calculator
    # itself never raises (an exception would break checkout transitions).
    attr_accessor :exception_handler

    # Object responding to `call(order)` returning a Hash of
    # `Spree::LineItem#id => BigDecimal` order-level discount allocated to each
    # line. See SolidusNumeral::DiscountCalculator for the default proration.
    attr_accessor :discount_calculator

    # Overrides `order_details.tax_included_in_amount` for every order. When
    # nil (default) the gem derives it per order: prices are treated as
    # tax-inclusive when a `Spree::TaxRate` with `included_in_price` covers
    # the order's tax address (so US-destination orders on a mixed US+VAT
    # store stay exclusive).
    attr_accessor :tax_included_in_price

    attr_writer :logger

    def initialize
      @api_key = nil
      @api_base = DEFAULT_API_BASE
      @enabled = true
      @cache_duration = 3.hours
      @exception_handler = ->(exception) {
        SolidusNumeral.config.logger.error(
          "[solidus_numeral] tax calculation failed - " \
          "#{exception.class}: #{exception.message}"
        )
      }
      @discount_calculator = SolidusNumeral::DiscountCalculator.new
      @tax_included_in_price = nil
      @logger = nil
    end

    def logger
      @logger || Rails.logger
    end
  end
end
