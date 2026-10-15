# frozen_string_literal: true

module SolidusNumeral
  # Whole-order tax calculator plugged into Solidus via
  # `Spree.config { |c| c.tax_calculator_class = "SolidusNumeral::TaxCalculator" }`.
  #
  # Solidus invokes this on every cart mutation and checkout transition, so
  # responses are cached keyed on the serialized request payload (identical
  # order states are free). It NEVER raises: any failure is routed through the
  # configured exception_handler and the order gets zero tax - an exception
  # here would break checkout transitions.
  class TaxCalculator
    PLACEHOLDER_TAX_RATE_NAME = "Numeral Tax"

    # Countries where a state/province is required for a calculation.
    STATE_REQUIRED_COUNTRIES = %w[US CA].freeze

    class << self
      # Warns (once per process - this guard runs on every cart mutation)
      # that the calculator is returning zero tax because the extension is
      # disabled or has no api_key. Without it a misconfigured store
      # silently under-collects on every order.
      def warn_not_calculating
        return if @not_calculating_warned

        @not_calculating_warned = true
        SolidusNumeral.config.logger.warn(
          "[solidus_numeral] tax calculation is OFF (enabled=" \
          "#{SolidusNumeral.config.enabled.inspect}, api_key " \
          "#{SolidusNumeral.config.api_key.present? ? 'present' : 'blank'}) " \
          "- all orders are getting zero tax (logged once per process)"
        )
      end

      # Process-wide cache of the placeholder rate's id: refetch by primary
      # key instead of running find_or_create_by! on every calculation.
      # Idempotent assignment, no mutex - concurrent first calls at worst
      # resolve the same named rate twice.
      def placeholder_tax_rate
        if @placeholder_tax_rate_id
          rate = ::Spree::TaxRate.find_by(id: @placeholder_tax_rate_id)
          return rate if rate
          # The cached rate was deleted; fall through and recreate it.
        end

        rate = ::Spree::TaxRate.find_or_create_by!(name: PLACEHOLDER_TAX_RATE_NAME) do |tax_rate|
          tax_rate.calculator = ::Spree::Calculator.new
          tax_rate.amount = 0
        end
        @placeholder_tax_rate_id = rate.id
        rate
      end

      # Test hook: clears the process-level warning + rate-id caches.
      def reset_process_caches!
        @not_calculating_warned = nil
        @placeholder_tax_rate_id = nil
      end
    end

    def initialize(order, api: nil)
      @order = order
      @api = api
    end

    # @return [Spree::Tax::OrderTax]
    def calculate
      return no_tax unless enabled?
      return no_tax if incomplete_address?(order.tax_address)
      return no_tax if order.line_items.none?

      entry = fetch_calculation
      return no_tax unless entry

      build_order_tax(entry.fetch("response"))
    rescue StandardError => exception
      SolidusNumeral.config.exception_handler.call(exception)
      no_tax
    end

    private

    attr_reader :order

    def api
      @api ||= SolidusNumeral.api_client
    end

    def enabled?
      return true if SolidusNumeral.config.enabled && SolidusNumeral.config.api_key.present?

      self.class.warn_not_calculating
      false
    end

    # Skips the store-default TaxLocation fallback (country-only, no street)
    # and structurally incomplete addresses. A state is only required for
    # US/CA, matching the API's own address validation.
    def incomplete_address?(address)
      return true if address.nil?
      return true if address.is_a?(::Spree::Tax::TaxLocation)

      fields = [address.address1, address.city, address.zipcode, address.country&.iso]

      if STATE_REQUIRED_COUNTRIES.include?(address.country&.iso)
        fields << (address.state&.abbr || address.state_name)
      end

      fields.any?(&:blank?)
    end

    # @return [Hash, nil] `{"request" =>, "response" =>}` entry
    def fetch_calculation
      payload = ApiParams.order_params(order)

      fetched = false
      entry = CalculationCache.fetch(payload) do
        fetched = true
        response = api.create_calculation(payload)
        { "request" => payload, "response" => response }
      end

      # Keep an order-keyed pointer so CommitTransactionJob can reuse the
      # checkout-time calculation (id + per-line amounts) at completion. Only
      # written when the block actually ran: on a request-cache hit the
      # pointer from the original miss is still current (both entries share
      # the same TTL).
      CalculationCache.write_latest_for_order(order, entry) if fetched

      entry
    end

    def build_order_tax(response)
      lines_by_reference = index_response_lines(response)
      included = response["tax_included_in_amount"] ? true : false
      currency = order.currency

      line_item_taxes = order.line_items.filter_map do |line_item|
        item_tax_for(
          lines_by_reference[line_item.id.to_s],
          item_id: line_item.id,
          included: included,
          currency: currency
        )
      end

      shipment_taxes = order.shipments.filter_map do |shipment|
        item_tax_for(
          lines_by_reference[ApiParams.shipment_reference_line_item_id(shipment)],
          item_id: shipment.id,
          included: included,
          currency: currency
        )
      end

      ::Spree::Tax::OrderTax.new(
        order_id: order.id,
        line_item_taxes: line_item_taxes,
        shipment_taxes: shipment_taxes
      )
    end

    def index_response_lines(response)
      Array(response["line_items"]).each_with_object({}) do |line, index|
        reference_id = line.dig("product", "reference_line_item_id")
        index[reference_id] = line if reference_id
      end
    end

    def item_tax_for(response_line, item_id:, included:, currency:)
      return nil unless response_line

      tax_amount = Money.from_minor_units(response_line["tax_amount"].to_i, currency)
      return nil if tax_amount.zero?

      ::Spree::Tax::ItemTax.new(
        item_id: item_id,
        label: label_for(response_line),
        tax_rate: placeholder_tax_rate,
        amount: tax_amount,
        included_in_price: included
      )
    end

    # "Sales Tax (8.875%)" when jurisdiction rates are available, plain
    # "Sales Tax" otherwise. Each jurisdiction row carries the rate for one
    # taxing authority; the effective rate is their sum.
    def label_for(response_line)
      rate_sum = Array(response_line["tax_jurisdictions"])
        .sum { |jurisdiction| jurisdiction["tax_rate"].to_f }

      return "Sales Tax" unless rate_sum.positive?

      percent = (rate_sum * 100).round(3)
      percent = percent.to_i if percent == percent.to_i
      "Sales Tax (#{percent}%)"
    end

    # Solidus requires every tax adjustment to reference a persisted
    # Spree::TaxRate (it becomes the adjustment's polymorphic source). The
    # actual amounts come from Numeral, so a single zero-amount placeholder
    # rate is used for all adjustments - the same pattern as solidus_taxjar,
    # including the bare Spree::Calculator instance. The rate id is cached
    # process-wide (see .placeholder_tax_rate).
    def placeholder_tax_rate
      @placeholder_tax_rate ||= self.class.placeholder_tax_rate
    end

    def no_tax
      ::Spree::Tax::OrderTax.new(
        order_id: order.id,
        line_item_taxes: [],
        shipment_taxes: []
      )
    end
  end
end
