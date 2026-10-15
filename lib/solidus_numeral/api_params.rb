# frozen_string_literal: true

require "set"

module SolidusNumeral
  # Builds Numeral API request payloads from Spree records.
  #
  # Field names follow the 2026-03-01 calculation schema:
  # - `amount` is a PER-UNIT integer in minor units; tax is computed on
  #   `amount * quantity`. Discounted totals are divided across the quantity
  #   and rounded (the same divide-and-round encoding used by all existing
  #   Numeral integrations); the resulting drift is at most quantity/2 cents.
  # - `default_customer_type` is a TOP-LEVEL field (not on `customer`) and
  #   prevents a 400 when `customer.id` references a customer Numeral does not
  #   know about.
  module ApiParams
    GENERAL_MERCHANDISE = "GENERAL_MERCHANDISE"
    SHIPPING_CATEGORY = "SHIPPING"
    MAX_REFERENCE_PRODUCT_ID_LENGTH = 255
    SHIPMENT_REFERENCE_PREFIX = "shipment-"

    # EU member states share the "eu_vat" tax id type.
    EU_COUNTRY_ISO_CODES = %w[
      AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK
      SI ES SE
    ].freeze

    # Destination country -> country-specific tax id type. The 2026-01-01+
    # schema rejects legacy types ("VAT", "GST", "EIN"); customer tax_ids must
    # use the country-specific enum (thomas TAX_ID_TYPES). This maps each
    # country to its VAT/GST registration type; countries without an entry get
    # no tax_ids (see business_customer_params).
    TAX_ID_TYPE_BY_COUNTRY = EU_COUNTRY_ISO_CODES
      .to_h { |iso| [iso, "eu_vat"] }
      .merge(
        "AE" => "ae_trn",
        "AU" => "au_abn",
        "BH" => "bh_vat",
        "CA" => "ca_gst_hst",
        "CH" => "ch_vat",
        "GB" => "gb_vat",
        "GE" => "ge_vat",
        "IL" => "il_vat",
        "IN" => "in_gst",
        "IS" => "is_vat",
        "JP" => "jp_trn",
        "LI" => "li_vat",
        "MA" => "ma_vat",
        "MD" => "md_vat",
        "MK" => "mk_vat",
        "NO" => "no_vat",
        "NZ" => "nz_gst",
        "OM" => "om_vat",
        "SA" => "sa_vat",
        "SG" => "sg_gst",
        "TH" => "th_vat",
        "TW" => "tw_vat",
        "TZ" => "tz_vat",
        "UA" => "ua_vat",
        "ZA" => "za_vat"
      ).freeze

    class << self
      # Full calculation request payload for an order.
      # @param order [Spree::Order]
      # @return [Hash]
      def order_params(order)
        customer = customer_params(order)

        payload = {
          customer: customer,
          order_details: {
            customer_currency_code: order.currency,
            tax_included_in_amount: tax_included_in_amount?(order),
            automatic_tax: "auto",
            line_items: line_items_params(order) + shipments_params(order),
          },
          metadata: { "solidus_order_number" => order.number.to_s },
        }

        origin = origin_address_params(order)
        payload[:origin_address] = origin if origin

        # Only meaningful alongside customer.id: if the referenced customer is
        # unknown to Numeral, the calculation proceeds treating them as a
        # consumer instead of failing.
        payload[:default_customer_type] = "CONSUMER" if customer.key?(:id)

        payload
      end

      # @param address [Spree::Address, Spree::StockLocation]
      def address_params(address)
        params = {
          address_line_1: address.address1.to_s,
          address_city: address.city.to_s,
          address_province: state_abbr(address),
          address_postal_code: address.zipcode.to_s,
          address_country: address.country&.iso.to_s,
        }
        params[:address_line_2] = address.address2 if address.address2.present?
        params
      end

      def shipment_reference_line_item_id(shipment)
        "#{SHIPMENT_REFERENCE_PREFIX}#{shipment.id}"
      end

      # Whether this ORDER's prices include tax. The explicit config override
      # wins; when it is nil we decide per order: inclusive only if a
      # tax-inclusive rate's zone covers the order's tax address (the same
      # `TaxRate.for_address` zone scoping Solidus's own tax engine uses).
      # A store-wide "any included_in_price rate exists" check would flip
      # US-destination orders on a mixed US+VAT store to inclusive and
      # systematically under-collect. One scoped query per payload build.
      def tax_included_in_amount?(order)
        configured = SolidusNumeral.config.tax_included_in_price
        return configured unless configured.nil?

        address = order.tax_address
        return false if address.nil?

        ::Spree::TaxRate
          .for_address(address)
          .where(included_in_price: true)
          .exists?
      end

      # Test hook: clears the once-per-country unmapped-tax-id-type warnings.
      def reset_tax_id_warnings!
        @warned_tax_id_countries = nil
      end

      private

      def customer_params(order)
        user = order.user

        params = {
          address: address_params(order.tax_address).merge(
            address_type: address_type
          ),
        }

        if user && synced_to_numeral?(user)
          params[:id] = user.id.to_s
        end

        vat_id = user.respond_to?(:numeral_vat_id) ? user.numeral_vat_id : nil
        if vat_id.present?
          params.merge!(business_customer_params(vat_id, order))
        else
          params[:type] = "CONSUMER"
        end

        params
      end

      # BUSINESS customer fields for a user with a stored VAT id. tax_ids must
      # use the country-specific type for the order's tax-address country
      # (see TAX_ID_TYPE_BY_COUNTRY). US business customers are sent without
      # tax_ids (the schema only requires them for non-US addresses). For a
      # destination with no valid type, sending BUSINESS without tax_ids would
      # 400 every calculation, so fall back to CONSUMER and warn.
      def business_customer_params(vat_id, order)
        country_iso = order.tax_address&.country&.iso.to_s

        return { type: "BUSINESS" } if country_iso == "US"

        tax_id_type = TAX_ID_TYPE_BY_COUNTRY[country_iso]
        if tax_id_type
          { type: "BUSINESS", tax_ids: [{ type: tax_id_type, value: vat_id }] }
        else
          warn_unmapped_tax_id_country(country_iso)
          { type: "CONSUMER" }
        end
      end

      # Once per country per process - this runs on every cart recalculation.
      def warn_unmapped_tax_id_country(country_iso)
        @warned_tax_id_countries ||= Set.new
        return if @warned_tax_id_countries.include?(country_iso)

        @warned_tax_id_countries << country_iso
        SolidusNumeral.config.logger.warn(
          "[solidus_numeral] no Numeral tax id type is mapped for country " \
          "#{country_iso.inspect}; the customer's VAT id is omitted and the " \
          "customer is sent as CONSUMER (logged once per country per process)"
        )
      end

      def address_type
        ::Spree::Config[:tax_using_ship_address] ? "shipping" : "billing"
      end

      def synced_to_numeral?(user)
        user.respond_to?(:numeral_customer_synced_at) &&
          user.numeral_customer_synced_at.present?
      end

      def state_abbr(address)
        if address.respond_to?(:state) && address.state
          address.state.abbr.to_s
        elsif address.respond_to?(:state_name)
          address.state_name.to_s
        else
          ""
        end
      end

      # Ship-from address, taken from the order's primary stock location (or
      # the store default) when it has a complete address. Omitted otherwise -
      # the calculation falls back to the client's configured origin.
      def origin_address_params(order)
        stock_location =
          order.shipments.detect(&:stock_location)&.stock_location ||
          ::Spree::StockLocation.find_by(default: true)

        return nil unless stock_location
        return nil unless complete_stock_location_address?(stock_location)

        address_params(stock_location)
      end

      def complete_stock_location_address?(stock_location)
        stock_location.address1.present? &&
          stock_location.city.present? &&
          stock_location.zipcode.present? &&
          stock_location.country&.iso.present?
      end

      def line_items_params(order)
        currency = order.currency
        discounts = SolidusNumeral.config.discount_calculator.call(order)

        order.line_items.filter_map do |line_item|
          next unless line_item.quantity.to_i.positive?

          # Post-promotion, pre-tax taxable base for the line, minus this
          # line's prorated share of any order-level discount.
          taxable_total =
            line_item.total_before_tax.to_d - (discounts[line_item.id] || 0).to_d

          per_unit = Money.per_unit_minor_units(
            total: taxable_total,
            quantity: line_item.quantity,
            currency: currency
          )

          params = {
            reference_line_item_id: line_item.id.to_s,
            amount: [per_unit, 0].max,
            quantity: line_item.quantity,
            fallback_product_category: GENERAL_MERCHANDISE,
          }

          sku = line_item.variant&.sku
          if sku.present?
            params[:reference_product_id] = sku.to_s[0, MAX_REFERENCE_PRODUCT_ID_LENGTH]
          end

          tax_code = line_item.tax_category&.tax_code
          params[:product_category] = tax_code if tax_code.present?

          params
        end
      end

      # One SHIPPING line per shipment. `total_before_tax` includes shipping
      # promotions (a fully-discounted shipment is sent as a zero amount).
      def shipments_params(order)
        currency = order.currency

        order.shipments.map do |shipment|
          {
            reference_line_item_id: shipment_reference_line_item_id(shipment),
            product_category: SHIPPING_CATEGORY,
            amount: [Money.to_minor_units(shipment.total_before_tax.to_d, currency), 0].max,
            quantity: 1,
          }
        end
      end
    end
  end
end
