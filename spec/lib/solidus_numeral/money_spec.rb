# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::Money do
  describe ".to_minor_units / .from_minor_units" do
    it "round-trips two-decimal currencies" do
      expect(described_class.to_minor_units(BigDecimal("12.34"), "USD")).to eq(1_234)
      expect(described_class.from_minor_units(1_234, "USD")).to eq(BigDecimal("12.34"))
    end

    it "rounds half-up" do
      expect(described_class.to_minor_units(BigDecimal("0.005"), "USD")).to eq(1)
    end

    it "handles zero-decimal currencies" do
      expect(described_class.to_minor_units(BigDecimal("1200"), "JPY")).to eq(1_200)
      expect(described_class.from_minor_units(1_200, "JPY")).to eq(BigDecimal("1200"))
    end
  end

  describe ".per_unit_minor_units" do
    it "divides the total across the quantity and rounds to an integer" do
      # $29.00 across 3 units: 966.67 cents -> 967
      expect(
        described_class.per_unit_minor_units(
          total: BigDecimal("29.00"), quantity: 3, currency: "USD"
        )
      ).to eq(967)
    end

    it "returns zero for non-positive quantities" do
      expect(
        described_class.per_unit_minor_units(
          total: BigDecimal("10"), quantity: 0, currency: "USD"
        )
      ).to eq(0)
    end
  end
end
