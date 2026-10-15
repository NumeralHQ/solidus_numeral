# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::DiscountCalculator do
  subject(:calculator) { described_class.new }

  def build_line_item(id:, total:, quantity: 1)
    double(
      "LineItem",
      id: id,
      quantity: quantity,
      total_before_tax: BigDecimal(total)
    )
  end

  def build_adjustment(amount:, tax: false)
    double(
      "Adjustment",
      amount: BigDecimal(amount),
      tax?: tax,
      marked_for_destruction?: false
    )
  end

  def build_order(line_items:, adjustments:)
    double("Order", line_items: line_items, adjustments: adjustments)
  end

  it "prorates order-level discounts by pre-discount line totals" do
    order = build_order(
      line_items: [
        build_line_item(id: 1, total: "75.00"),
        build_line_item(id: 2, total: "25.00"),
      ],
      adjustments: [build_adjustment(amount: "-10.00")]
    )

    shares = calculator.call(order)

    expect(shares[1]).to eq(BigDecimal("7.50"))
    expect(shares[2]).to eq(BigDecimal("2.50"))
    expect(shares.values.sum).to eq(BigDecimal("10.00"))
  end

  it "returns an empty hash when there is no order-level discount" do
    order = build_order(
      line_items: [build_line_item(id: 1, total: "75.00")],
      adjustments: []
    )

    expect(calculator.call(order)).to eq({})
  end

  it "ignores tax adjustments and positive adjustments" do
    order = build_order(
      line_items: [build_line_item(id: 1, total: "100.00")],
      adjustments: [
        build_adjustment(amount: "-5.00", tax: true),
        build_adjustment(amount: "3.00"),
      ]
    )

    expect(calculator.call(order)).to eq({})
  end

  it "allocates the exact total across lines (remainder to the last line)" do
    order = build_order(
      line_items: [
        build_line_item(id: 1, total: "10.00"),
        build_line_item(id: 2, total: "10.00"),
        build_line_item(id: 3, total: "10.00"),
      ],
      adjustments: [build_adjustment(amount: "-10.00")]
    )

    shares = calculator.call(order)

    expect(shares.values.sum).to eq(BigDecimal("10.00"))
  end

  it "never allocates more than a line's own total" do
    order = build_order(
      line_items: [
        build_line_item(id: 1, total: "1.00"),
        build_line_item(id: 2, total: "99.00"),
      ],
      adjustments: [build_adjustment(amount: "-100.00")]
    )

    shares = calculator.call(order)

    expect(shares[1]).to be <= BigDecimal("1.00")
    expect(shares[2]).to be <= BigDecimal("99.00")
  end

  it "skips zero-quantity lines" do
    order = build_order(
      line_items: [
        build_line_item(id: 1, total: "10.00", quantity: 0),
        build_line_item(id: 2, total: "10.00"),
      ],
      adjustments: [build_adjustment(amount: "-4.00")]
    )

    shares = calculator.call(order)

    expect(shares).not_to have_key(1)
    expect(shares[2]).to eq(BigDecimal("4.00"))
  end
end
