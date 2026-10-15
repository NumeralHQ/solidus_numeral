# frozen_string_literal: true

module SolidusNumeral
  # Default order-level discount allocator.
  #
  # Line-level promotions are already reflected in each line item's
  # `total_before_tax`, but ORDER-level promotion adjustments (negative
  # adjustments whose adjustable is the order itself) are not part of any
  # line's total. Numeral's calculation API has no discount field, so those
  # order-level discounts must be prorated across the line items before the
  # per-unit amounts are encoded.
  #
  # This default prorates by each line's pre-discount `total_before_tax`. The
  # allocator is pluggable via `SolidusNumeral.config.discount_calculator`; a
  # replacement must respond to `call(order)` and return a Hash of
  # `Spree::LineItem#id => BigDecimal` (a positive amount, in the order's
  # currency, to subtract from that line's taxable total).
  class DiscountCalculator
    # @param order [Spree::Order]
    # @return [Hash{Integer => BigDecimal}]
    def call(order)
      line_items = order.line_items.reject { |line_item| line_item.quantity.to_i <= 0 }
      return {} if line_items.empty?

      discount_total = order_level_discount_total(order)
      return {} unless discount_total.positive?

      weights = line_items.to_h { |line_item| [line_item.id, line_item.total_before_tax.to_d] }
      total_weight = weights.values.sum
      return {} unless total_weight.positive?

      shares = {}
      allocated = 0.to_d
      line_items.each_with_index do |line_item, index|
        share =
          if index == line_items.size - 1
            # Give the remainder to the last line so the shares sum exactly.
            discount_total - allocated
          else
            discount_total * (weights[line_item.id] / total_weight)
          end

        # A discount can never push a line below zero.
        share = share.clamp(0.to_d, weights[line_item.id])
        allocated += share
        shares[line_item.id] = share
      end

      shares
    end

    private

    # Sum of negative, non-tax adjustments sitting on the order itself
    # (promotions and manual order-level discounts), as a positive number.
    def order_level_discount_total(order)
      order.adjustments
        .reject { |adjustment| adjustment.tax? || adjustment.marked_for_destruction? }
        .select { |adjustment| adjustment.amount.negative? }
        .sum(0.to_d) { |adjustment| adjustment.amount.to_d }
        .abs
    end
  end
end
