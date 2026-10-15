# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::RefundParams do
  describe ".reimbursement_requested_lines" do
    let(:line_item) { double("LineItem", id: 101) }
    let(:other_line_item) { double("LineItem", id: 102) }

    def build_return_item(line_item:, amount:, additional_tax: "0", included_tax: "0")
      double(
        "ReturnItem",
        inventory_unit: double("InventoryUnit", line_item: line_item),
        amount: BigDecimal(amount),
        additional_tax_total: BigDecimal(additional_tax),
        included_tax_total: BigDecimal(included_tax)
      )
    end

    def build_reimbursement(return_items)
      double(
        "Reimbursement",
        order: double("Order", currency: "USD"),
        return_items: return_items
      )
    end

    it "groups return items by original line item and sums pre-tax and tax amounts" do
      reimbursement = build_reimbursement([
        build_return_item(line_item: line_item, amount: "50.00", additional_tax: "4.44"),
        build_return_item(line_item: line_item, amount: "50.00", additional_tax: "4.44"),
        build_return_item(line_item: other_line_item, amount: "10.00", additional_tax: "0.80"),
      ])

      requested = described_class.reimbursement_requested_lines(
        reimbursement, tax_included: false
      )

      expect(requested).to eq(
        "101" => { "sales" => 10_000, "tax" => 888, "quantity" => 2 },
        "102" => { "sales" => 1_000, "tax" => 80, "quantity" => 1 }
      )
    end

    it "sends GROSS sales for a tax-inclusive transaction (Numeral caps against gross)" do
      reimbursement = build_reimbursement([
        build_return_item(line_item: line_item, amount: "120.00", included_tax: "20.00"),
      ])

      requested = described_class.reimbursement_requested_lines(
        reimbursement, tax_included: true
      )

      expect(requested).to eq(
        "101" => { "sales" => 12_000, "tax" => 2_000, "quantity" => 1 }
      )
    end

    it "backs included tax out of the sales amount for an exclusive transaction" do
      reimbursement = build_reimbursement([
        build_return_item(line_item: line_item, amount: "120.00", included_tax: "20.00"),
      ])

      requested = described_class.reimbursement_requested_lines(
        reimbursement, tax_included: false
      )

      expect(requested).to eq(
        "101" => { "sales" => 10_000, "tax" => 2_000, "quantity" => 1 }
      )
    end

    it "skips return items with no resolvable line item" do
      orphan = double(
        "ReturnItem",
        inventory_unit: double("InventoryUnit", line_item: nil),
        amount: BigDecimal("10"),
        additional_tax_total: BigDecimal("1"),
        included_tax_total: BigDecimal("0")
      )

      requested = described_class.reimbursement_requested_lines(
        build_reimbursement([orphan]), tax_included: false
      )

      expect(requested).to eq({})
    end
  end

  describe ".current_order_lines" do
    it "encodes lines exactly like the calculation payload (per-unit rounding included)" do
      line_item = double(
        "LineItem",
        id: 101,
        quantity: 3,
        total_before_tax: BigDecimal("29.00")
      )
      shipment = double("Shipment", id: 7, total_before_tax: BigDecimal("10.00"))
      order = double(
        "Order",
        currency: "USD",
        line_items: [line_item],
        shipments: [shipment],
        adjustments: []
      )

      current = described_class.current_order_lines(order)

      # 29.00 / 3 -> 966.67 cents -> 967 per unit * 3 = 2901
      expect(current).to eq(
        "101" => 2_901,
        "shipment-7" => 1_000
      )
    end
  end
end
