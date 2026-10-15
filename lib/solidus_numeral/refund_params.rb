# frozen_string_literal: true

module SolidusNumeral
  # Converts Solidus reimbursement / order state into RefundMath's
  # `requested` / `current` shapes (integer minor units keyed by
  # reference_line_item_id).
  module RefundParams
    class << self
      # Refund request amounts for a performed reimbursement, grouped by the
      # original line item through each return item's inventory unit.
      #
      # Sales denomination must match the committed snapshot (see RefundMath):
      # for a tax-inclusive transaction Numeral expects GROSS sales amounts,
      # and `ReturnItem#amount` already includes the VAT - send it as is. For
      # an exclusive transaction sales are net, so any included tax is backed
      # out. Tax refunded is the sum of additional + included tax either way.
      #
      # @param reimbursement [Spree::Reimbursement]
      # @param tax_included [Boolean] whether the committed transaction was
      #   tax-inclusive (OrderTransaction#tax_included_in_amount?)
      # @return [Hash] RefundMath `requested` shape
      def reimbursement_requested_lines(reimbursement, tax_included:)
        currency = reimbursement.order.currency

        grouped = reimbursement.return_items.group_by do |return_item|
          return_item.inventory_unit&.line_item
        end

        grouped.each_with_object({}) do |(line_item, return_items), result|
          next unless line_item

          sales_total = return_items.sum(0.to_d) do |return_item|
            if tax_included
              return_item.amount.to_d
            else
              return_item.amount.to_d - return_item.included_tax_total.to_d
            end
          end
          tax_total = return_items.sum(0.to_d) do |return_item|
            return_item.additional_tax_total.to_d + return_item.included_tax_total.to_d
          end

          result[line_item.id.to_s] = {
            "sales" => [Money.to_minor_units(sales_total, currency), 0].max,
            "tax" => [Money.to_minor_units(tax_total, currency), 0].max,
            "quantity" => return_items.size,
          }
        end
      end

      # Current per-line amounts for an order, encoded exactly the way the
      # committed calculation encoded them (per-unit rounding included), so
      # short-ship deltas diff like against like.
      #
      # Denomination matches the committed snapshot in both modes without any
      # branching: `total_before_tax` is post-discount and pre-ADDITIONAL-tax,
      # so under inclusive pricing it is gross (the VAT is embedded in the
      # price) - the same base the calculation payload's `amount` was built
      # from, and therefore the same base as the snapshot's refundable amount
      # (`amount_including_tax` when inclusive, `amount_excluding_tax` when
      # exclusive).
      #
      # @param order [Spree::Order]
      # @return [Hash{String => Integer}] RefundMath `current` shape
      def current_order_lines(order)
        currency = order.currency
        discounts = SolidusNumeral.config.discount_calculator.call(order)

        current = {}

        order.line_items.each do |line_item|
          quantity = line_item.quantity.to_i
          next unless quantity.positive?

          taxable_total =
            line_item.total_before_tax.to_d - (discounts[line_item.id] || 0).to_d
          per_unit = Money.per_unit_minor_units(
            total: taxable_total,
            quantity: quantity,
            currency: currency
          )
          current[line_item.id.to_s] = [per_unit, 0].max * quantity
        end

        order.shipments.each do |shipment|
          current[ApiParams.shipment_reference_line_item_id(shipment)] =
            [Money.to_minor_units(shipment.total_before_tax.to_d, currency), 0].max
        end

        current
      end
    end
  end
end
