# frozen_string_literal: true

module SolidusNumeral
  # Shipping-rate tax calculator for the checkout delivery step.
  #
  # Solidus calls this once per CANDIDATE shipping rate of every shipping
  # method when proposed shipments are built - a naive implementation would
  # fire N API calls per delivery step for amounts that are display-only
  # (Spree::ShippingRateTax records never become adjustments). This is a
  # deliberate no-op: the delivery step shows shipping prices without an
  # estimated tax line, and the real shipping tax is calculated (and charged)
  # by SolidusNumeral::TaxCalculator on the next order recalculation, which
  # sends each shipment as a SHIPPING line item.
  class ShippingRateTaxCalculator
    def initialize(order)
      @order = order
    end

    # @param shipping_rate [Spree::ShippingRate]
    # @return [Array<Spree::Tax::ItemTax>] always empty
    def calculate(shipping_rate)
      []
    end

    private

    attr_reader :order
  end
end
