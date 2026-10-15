# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::ApiParams do
  let(:country) { double("Country", iso: "US") }
  let(:state) { double("State", abbr: "NY") }

  let(:tax_address) do
    double(
      "Address",
      address1: "350 5th Ave",
      address2: nil,
      city: "New York",
      state: state,
      state_name: nil,
      zipcode: "10118",
      country: country
    )
  end

  let(:stock_location) do
    double(
      "StockLocation",
      address1: "1 Warehouse Way",
      address2: nil,
      city: "Reno",
      state: double("State", abbr: "NV"),
      state_name: nil,
      zipcode: "89501",
      country: double("Country", iso: "US")
    )
  end

  let(:shipment) do
    double(
      "Shipment",
      id: 7,
      total_before_tax: BigDecimal("10"),
      stock_location: stock_location
    )
  end

  def build_line_item(id:, quantity:, total_before_tax:, sku: "SKU-#{id}", tax_code: nil)
    double(
      "LineItem",
      id: id,
      quantity: quantity,
      total_before_tax: BigDecimal(total_before_tax.to_s),
      variant: double("Variant", sku: sku),
      tax_category: tax_code && double("TaxCategory", tax_code: tax_code)
    )
  end

  def build_order(line_items:, shipments: [shipment], user: nil, adjustments: [])
    double(
      "Order",
      number: "R123456789",
      currency: "USD",
      user: user,
      tax_address: tax_address,
      line_items: line_items,
      shipments: shipments,
      adjustments: adjustments
    )
  end

  before do
    allow(::Spree::Config).to receive(:[]).with(:tax_using_ship_address).and_return(true)
  end

  describe ".order_params" do
    it "builds the full 2026-03-01 calculation payload" do
      order = build_order(
        line_items: [build_line_item(id: 101, quantity: 2, total_before_tax: "100.00", tax_code: "CLOTHING")]
      )

      payload = described_class.order_params(order)

      expect(payload).to eq(
        customer: {
          address: {
            address_line_1: "350 5th Ave",
            address_city: "New York",
            address_province: "NY",
            address_postal_code: "10118",
            address_country: "US",
            address_type: "shipping",
          },
          type: "CONSUMER",
        },
        origin_address: {
          address_line_1: "1 Warehouse Way",
          address_city: "Reno",
          address_province: "NV",
          address_postal_code: "89501",
          address_country: "US",
        },
        order_details: {
          customer_currency_code: "USD",
          tax_included_in_amount: false,
          automatic_tax: "auto",
          line_items: [
            {
              reference_line_item_id: "101",
              amount: 5_000,
              quantity: 2,
              fallback_product_category: "GENERAL_MERCHANDISE",
              reference_product_id: "SKU-101",
              product_category: "CLOTHING",
            },
            {
              reference_line_item_id: "shipment-7",
              product_category: "SHIPPING",
              amount: 1_000,
              quantity: 1,
            },
          ],
        },
        metadata: { "solidus_order_number" => "R123456789" }
      )
    end

    it "encodes discounted lines as rounded per-unit amounts, keeping quantity" do
      # 3 units, $29.00 after discount: 966.67 cents/unit -> 967
      order = build_order(
        line_items: [build_line_item(id: 5, quantity: 3, total_before_tax: "29.00")],
        shipments: []
      )

      payload = described_class.order_params(order)
      line = payload[:order_details][:line_items].first

      expect(line[:amount]).to eq(967)
      expect(line[:quantity]).to eq(3)
    end

    it "subtracts the prorated order-level discount before computing per-unit amounts" do
      order = build_order(
        line_items: [build_line_item(id: 5, quantity: 2, total_before_tax: "100.00")],
        shipments: []
      )
      SolidusNumeral.config.discount_calculator = ->(_order) { { 5 => BigDecimal("10") } }

      payload = described_class.order_params(order)

      expect(payload[:order_details][:line_items].first[:amount]).to eq(4_500)
    end

    it "omits product_category when the tax category has no tax_code and clamps at zero" do
      order = build_order(
        line_items: [build_line_item(id: 5, quantity: 1, total_before_tax: "-3.00")],
        shipments: []
      )

      line = described_class.order_params(order)[:order_details][:line_items].first

      expect(line).not_to have_key(:product_category)
      expect(line[:fallback_product_category]).to eq("GENERAL_MERCHANDISE")
      expect(line[:amount]).to eq(0)
    end

    it "skips zero-quantity lines" do
      order = build_order(
        line_items: [build_line_item(id: 5, quantity: 0, total_before_tax: "0")],
        shipments: []
      )

      expect(described_class.order_params(order)[:order_details][:line_items]).to be_empty
    end

    it "omits origin_address when the stock location address is incomplete" do
      allow(stock_location).to receive(:address1).and_return("")
      order = build_order(
        line_items: [build_line_item(id: 5, quantity: 1, total_before_tax: "10")]
      )
      allow(::Spree::StockLocation).to receive(:find_by).with(default: true).and_return(nil)

      expect(described_class.order_params(order)).not_to have_key(:origin_address)
    end

    context "with a synced user" do
      let(:user) do
        double(
          "User",
          id: 42,
          numeral_customer_synced_at: Time.utc(2026, 1, 1),
          numeral_vat_id: nil
        )
      end

      it "sends customer.id and the top-level default_customer_type" do
        order = build_order(
          line_items: [build_line_item(id: 5, quantity: 1, total_before_tax: "10")],
          user: user
        )

        payload = described_class.order_params(order)

        expect(payload[:customer][:id]).to eq("42")
        expect(payload[:default_customer_type]).to eq("CONSUMER")
      end
    end

    context "with an unsynced user" do
      let(:user) do
        double("User", id: 42, numeral_customer_synced_at: nil, numeral_vat_id: nil)
      end

      it "sends no customer.id and no default_customer_type" do
        order = build_order(
          line_items: [build_line_item(id: 5, quantity: 1, total_before_tax: "10")],
          user: user
        )

        payload = described_class.order_params(order)

        expect(payload[:customer]).not_to have_key(:id)
        expect(payload).not_to have_key(:default_customer_type)
      end
    end

    context "with a VAT id on the user" do
      let(:user) do
        double(
          "User",
          id: 42,
          numeral_customer_synced_at: nil,
          numeral_vat_id: "DE123456789"
        )
      end

      let(:logger) { double("Logger", warn: nil) }

      before do
        described_class.reset_tax_id_warnings!
        SolidusNumeral.config.logger = logger
      end

      def customer_for_country(iso)
        allow(country).to receive(:iso).and_return(iso)
        order = build_order(
          line_items: [build_line_item(id: 5, quantity: 1, total_before_tax: "10")],
          user: user
        )
        described_class.order_params(order)[:customer]
      end

      it "sends the country-specific eu_vat type for an EU destination" do
        customer = customer_for_country("DE")

        expect(customer[:type]).to eq("BUSINESS")
        expect(customer[:tax_ids]).to eq([{ type: "eu_vat", value: "DE123456789" }])
      end

      it "sends gb_vat for a UK destination" do
        expect(customer_for_country("GB")[:tax_ids])
          .to eq([{ type: "gb_vat", value: "DE123456789" }])
      end

      it "sends a BUSINESS customer without tax_ids for a US destination" do
        customer = customer_for_country("US")

        expect(customer[:type]).to eq("BUSINESS")
        expect(customer).not_to have_key(:tax_ids)
      end

      it "falls back to CONSUMER (no tax_ids) and warns once for an unmapped country" do
        2.times do
          customer = customer_for_country("BR")

          expect(customer[:type]).to eq("CONSUMER")
          expect(customer).not_to have_key(:tax_ids)
        end

        expect(logger).to have_received(:warn).once.with(/no Numeral tax id type.*"BR"/m)
      end
    end
  end

  describe ".tax_included_in_amount?" do
    let(:order) { build_order(line_items: []) }

    it "prefers the configured value" do
      SolidusNumeral.config.tax_included_in_price = true

      expect(described_class.tax_included_in_amount?(order)).to be(true)
    end

    it "derives per order from included_in_price rates covering the tax address" do
      SolidusNumeral.config.tax_included_in_price = nil
      inclusive_rates = double("Relation", exists?: true)
      address_rates = double("Relation")
      allow(::Spree::TaxRate).to receive(:for_address)
        .with(tax_address).and_return(address_rates)
      allow(address_rates).to receive(:where)
        .with(included_in_price: true).and_return(inclusive_rates)

      expect(described_class.tax_included_in_amount?(order)).to be(true)
    end

    it "is false when no rate zone covers the address" do
      SolidusNumeral.config.tax_included_in_price = nil
      inclusive_rates = double("Relation", exists?: false)
      address_rates = double("Relation", where: inclusive_rates)
      allow(::Spree::TaxRate).to receive(:for_address).and_return(address_rates)

      expect(described_class.tax_included_in_amount?(order)).to be(false)
    end

    it "is false without a tax address" do
      SolidusNumeral.config.tax_included_in_price = nil
      allow(order).to receive(:tax_address).and_return(nil)

      expect(described_class.tax_included_in_amount?(order)).to be(false)
    end
  end
end
