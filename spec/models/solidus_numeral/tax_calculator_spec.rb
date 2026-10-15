# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::TaxCalculator do
  subject(:calculator) { described_class.new(order, api: api) }

  let(:api) { double("ApiClient") }
  let(:placeholder_rate) { double("Spree::TaxRate", id: 77) }

  let(:country) { double("Country", iso: "US") }
  let(:address) do
    double(
      "Address",
      address1: "350 5th Ave",
      city: "New York",
      zipcode: "10118",
      country: country,
      state: double("State", abbr: "NY"),
      state_name: nil
    )
  end

  let(:line_item) { double("LineItem", id: 101) }
  let(:shipment) { double("Shipment", id: 7) }

  let(:order) do
    double(
      "Order",
      id: 900,
      currency: "USD",
      tax_address: address,
      line_items: [line_item],
      shipments: [shipment]
    )
  end

  let(:payload) { { some: "payload" } }

  let(:response) do
    {
      "id" => "calc_1",
      "expires_at" => 1_790_000_000,
      "tax_included_in_amount" => false,
      "line_items" => [
        {
          "product" => { "reference_line_item_id" => "101" },
          "tax_amount" => 888,
          "amount_excluding_tax" => 10_000,
          "quantity" => 2,
          "tax_jurisdictions" => [
            { "tax_rate" => 0.04, "tax_authority_name" => "NEW YORK" },
            { "tax_rate" => 0.04875, "tax_authority_name" => "NYC" },
          ],
        },
        {
          "product" => { "reference_line_item_id" => "shipment-7" },
          "tax_amount" => 89,
          "amount_excluding_tax" => 1_000,
          "quantity" => 1,
          "tax_jurisdictions" => [],
        },
      ],
    }
  end

  before do
    described_class.reset_process_caches!
    allow(SolidusNumeral::ApiParams).to receive(:order_params)
      .with(order).and_return(payload)
    allow(SolidusNumeral::CalculationCache).to receive(:fetch) { |_payload, &block| block.call }
    allow(SolidusNumeral::CalculationCache).to receive(:write_latest_for_order)
    allow(::Spree::TaxRate).to receive(:find_or_create_by!)
      .with(name: "Numeral Tax").and_return(placeholder_rate)
    allow(::Spree::TaxRate).to receive(:find_by)
      .with(id: placeholder_rate.id).and_return(placeholder_rate)
  end

  after { described_class.reset_process_caches! }

  describe "#calculate" do
    it "maps response lines back to line items and shipments by reference id" do
      allow(api).to receive(:create_calculation).with(payload).and_return(response)

      result = calculator.calculate

      expect(result).to be_a(::Spree::Tax::OrderTax)
      expect(result.order_id).to eq(900)

      expect(result.line_item_taxes.size).to eq(1)
      item_tax = result.line_item_taxes.first
      expect(item_tax.item_id).to eq(101)
      expect(item_tax.amount).to eq(BigDecimal("8.88"))
      expect(item_tax.label).to eq("Sales Tax (8.875%)")
      expect(item_tax.tax_rate).to eq(placeholder_rate)
      expect(item_tax.included_in_price).to be(false)

      expect(result.shipment_taxes.size).to eq(1)
      shipment_tax = result.shipment_taxes.first
      expect(shipment_tax.item_id).to eq(7)
      expect(shipment_tax.amount).to eq(BigDecimal("0.89"))
      expect(shipment_tax.label).to eq("Sales Tax")
    end

    it "stores the request+response entry for the commit job to reuse" do
      allow(api).to receive(:create_calculation).and_return(response)

      calculator.calculate

      expect(SolidusNumeral::CalculationCache)
        .to have_received(:write_latest_for_order)
        .with(order, { "request" => payload, "response" => response })
    end

    it "does not rewrite the order pointer on a request-cache hit" do
      cached_entry = { "request" => payload, "response" => response }
      allow(SolidusNumeral::CalculationCache).to receive(:fetch).and_return(cached_entry)

      calculator.calculate

      expect(SolidusNumeral::CalculationCache)
        .not_to have_received(:write_latest_for_order)
    end

    it "resolves the placeholder rate by cached id after the first calculation" do
      allow(api).to receive(:create_calculation).and_return(response)

      calculator.calculate
      described_class.new(order, api: api).calculate

      expect(::Spree::TaxRate).to have_received(:find_or_create_by!).once
      expect(::Spree::TaxRate).to have_received(:find_by).with(id: 77).once
    end

    it "recreates the placeholder rate when the cached one was deleted" do
      allow(api).to receive(:create_calculation).and_return(response)
      allow(::Spree::TaxRate).to receive(:find_by).with(id: 77).and_return(nil)

      calculator.calculate
      described_class.new(order, api: api).calculate

      expect(::Spree::TaxRate).to have_received(:find_or_create_by!).twice
    end

    it "omits zero-tax lines" do
      response["line_items"].each { |line| line["tax_amount"] = 0 }
      allow(api).to receive(:create_calculation).and_return(response)

      result = calculator.calculate

      expect(result.line_item_taxes).to be_empty
      expect(result.shipment_taxes).to be_empty
    end

    it "flags included_in_price when the response is tax-inclusive" do
      response["tax_included_in_amount"] = true
      allow(api).to receive(:create_calculation).and_return(response)

      result = calculator.calculate

      expect(result.line_item_taxes.first.included_in_price).to be(true)
    end

    context "guards (no API call is made)" do
      before do
        # Re-raise instead of swallowing, so an unexpected API call (the
        # unstubbed double) fails the example instead of degrading to no_tax.
        SolidusNumeral.config.exception_handler = ->(exception) { raise exception }
      end

      after do
        result = calculator.calculate

        expect(result.line_item_taxes).to be_empty
        expect(result.shipment_taxes).to be_empty
      end

      it "returns zero tax when disabled" do
        SolidusNumeral.config.enabled = false
      end

      it "returns zero tax without an api key" do
        SolidusNumeral.config.api_key = nil
      end

      it "returns zero tax for the store-default TaxLocation fallback" do
        allow(order).to receive(:tax_address)
          .and_return(::Spree::Tax::TaxLocation.new)
      end

      it "returns zero tax for a nil address" do
        allow(order).to receive(:tax_address).and_return(nil)
      end

      it "returns zero tax when the address is missing a street" do
        allow(address).to receive(:address1).and_return("")
      end

      it "returns zero tax when a US address is missing its state" do
        allow(address).to receive(:state).and_return(nil)
        allow(address).to receive(:state_name).and_return(nil)
      end

      it "returns zero tax when the order has no line items" do
        allow(order).to receive(:line_items).and_return([])
      end
    end

    context "when disabled or unconfigured" do
      let(:logger) { double("Logger", warn: nil) }

      before { SolidusNumeral.config.logger = logger }

      it "warns loudly, but only once per process, when disabled" do
        SolidusNumeral.config.enabled = false

        2.times { described_class.new(order, api: api).calculate }

        expect(logger).to have_received(:warn).once.with(/zero tax/)
      end

      it "warns when the api_key is blank" do
        SolidusNumeral.config.api_key = ""

        calculator.calculate

        expect(logger).to have_received(:warn).once.with(/api_key blank/)
      end
    end

    it "does not require a state outside US/CA" do
      allow(country).to receive(:iso).and_return("DE")
      allow(address).to receive(:state).and_return(nil)
      allow(address).to receive(:state_name).and_return(nil)
      allow(api).to receive(:create_calculation).and_return(response)

      calculator.calculate

      expect(api).to have_received(:create_calculation)
    end

    it "never raises: API failures go to the exception handler and yield zero tax" do
      handled = []
      SolidusNumeral.config.exception_handler = ->(exception) { handled << exception }
      allow(api).to receive(:create_calculation)
        .and_raise(SolidusNumeral::ApiError.new("boom", status: 500))

      result = calculator.calculate

      expect(result.line_item_taxes).to be_empty
      expect(handled.first).to be_a(SolidusNumeral::ApiError)
    end
  end
end
