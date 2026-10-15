# frozen_string_literal: true

module SolidusNumeral
  # Pure refund arithmetic, in integer minor units, over the committed
  # line-item snapshot stored on SolidusNumeral::OrderTransaction.
  #
  # Shapes (all keyed by reference_line_item_id strings):
  # - committed: {"amount_excluding_tax" => Integer, "amount_including_tax" => Integer,
  #               "tax_amount" => Integer, "quantity" => Integer,
  #               "tax_included_in_amount" => Boolean}
  #   (from the calculation response the transaction was committed from)
  # - refunded:  {"sales_amount_refunded" => Integer (<= 0, cumulative),
  #               "tax_amount_refunded" => Integer (<= 0, cumulative)}
  # - requested: {"sales" => Integer (>= 0), "tax" => Integer (>= 0), "quantity" => Integer}
  #
  # Denomination: Numeral treats `sales_amount_refunded` as tax-INCLUSIVE
  # (gross) when the purchase was committed with `tax_included_in_amount`,
  # and net otherwise, and caps cumulative refunds against the corresponding
  # stored amount (thomas `getRefundSalesAmount`: `amount_including_tax` for
  # inclusive lines, `amount_excluding_tax` for exclusive). All sales values
  # here (requested, refunded, headroom) follow the same rule.
  #
  # All caps are computed against the COMMITTED snapshot (the amounts Numeral
  # actually stored), never against Solidus's own totals: per-unit rounding
  # means the two can drift by a few cents, and an over-refund is rejected by
  # the API ("Refund cannot be greater than the original amount").
  module RefundMath
    class << self
      # Caps requested refund lines against the remaining per-line headroom and
      # returns Numeral refund line_items. Lines whose capped sales amount is
      # zero are dropped (the API requires sales_amount_refunded < 0).
      #
      # @return [Array<Hash>] e.g.
      #   [{reference_line_item_id:, sales_amount_refunded: -100, tax_amount_refunded: -8, quantity: 1}]
      def cap_refund_lines(requested:, committed:, refunded:)
        requested.filter_map do |reference_id, request|
          line = committed[reference_id]
          next unless line

          sales_headroom, tax_headroom = remaining_for_line(
            line, refunded[reference_id]
          )

          sales = [[request.fetch("sales", 0), 0].max, sales_headroom].min
          tax = [[request.fetch("tax", 0), 0].max, tax_headroom].min
          next unless sales.positive?

          {
            reference_line_item_id: reference_id,
            sales_amount_refunded: -sales,
            tax_amount_refunded: -tax,
            quantity: [request.fetch("quantity", 1).to_i, 1].max,
          }
        end
      end

      # Refund line items consuming the full remaining per-line headroom.
      # Used by order cancellation when partial refunds were already recorded.
      # Lines with no sales headroom left are dropped.
      def remaining_refund_lines(committed:, refunded:)
        committed.filter_map do |reference_id, line|
          sales, tax = remaining_for_line(line, refunded[reference_id])
          next unless sales.positive?

          {
            reference_line_item_id: reference_id,
            sales_amount_refunded: -sales,
            tax_amount_refunded: -tax,
            quantity: [line.fetch("quantity", 1).to_i, 1].max,
          }
        end
      end

      # Delta refund requests for a short-ship / downward order edit: for each
      # committed line whose current amount is below its remaining
      # (committed - already refunded) amount, request the decrease, with tax
      # prorated from the committed tax at the committed effective rate.
      #
      # @param current [Hash{String => Integer}] reference_line_item_id =>
      #   current amount in minor units (per-unit amount * quantity for line
      #   items, total for shipments). Missing keys mean the line was removed.
      def short_ship_deltas(committed:, refunded:, current:)
        committed.each_with_object({}) do |(reference_id, line), result|
          sales_headroom, tax_headroom = remaining_for_line(
            line, refunded[reference_id]
          )
          next unless sales_headroom.positive?

          delta = sales_headroom - [current.fetch(reference_id, 0), 0].max
          next unless delta.positive?

          committed_sales = refundable_sales(line)
          committed_tax = line.fetch("tax_amount", 0)
          tax =
            if committed_sales.positive? && committed_tax.positive?
              ((delta.to_f / committed_sales) * committed_tax).round
            else
              0
            end

          result[reference_id] = {
            "sales" => delta,
            "tax" => [tax, tax_headroom].min,
            "quantity" => [line.fetch("quantity", 1).to_i, 1].max,
          }
        end
      end

      # Folds freshly-sent refund line_items into the cumulative refunded
      # hash. Returns a new hash (does not mutate).
      def accumulate(refunded, refund_line_items)
        refund_line_items.each_with_object(deep_copy(refunded)) do |line, result|
          reference_id = line[:reference_line_item_id] || line["reference_line_item_id"]
          entry = result[reference_id] ||= {
            "sales_amount_refunded" => 0,
            "tax_amount_refunded" => 0,
          }
          entry["sales_amount_refunded"] +=
            (line[:sales_amount_refunded] || line["sales_amount_refunded"]).to_i
          entry["tax_amount_refunded"] +=
            (line[:tax_amount_refunded] || line["tax_amount_refunded"]).to_i
        end
      end

      # Rebuilds the cumulative refunded hash from the refund list returned by
      # GET /tax/transactions/:id/refunds (server truth). Server refund line
      # items echo the original line's `product.reference_line_item_id` and
      # carry negative TOTAL amounts; a full refund is represented as a refund
      # whose line items invert every committed line, so it needs no
      # special-casing. Sales are re-denominated per line exactly the way
      # Numeral caps them (gross when tax-inclusive, net otherwise);
      # `default_tax_included` covers lines missing from the committed
      # snapshot.
      #
      # Lines without a reference_line_item_id (refunds created outside this
      # gem, matched by product id against lines that never carried one)
      # cannot be attributed to a committed line; each is yielded as
      # `(refund, line)` for logging, then skipped.
      #
      # @param refunds [Array<Hash>] `response["refunds"]` objects
      # @return [Hash] the `refunded` shape (see module doc)
      def refunded_from_server(refunds:, committed:, default_tax_included: false)
        refunds.each_with_object({}) do |refund, result|
          Array(refund["line_items"]).each do |line|
            reference_id = line.dig("product", "reference_line_item_id").to_s
            if reference_id.empty?
              yield(refund, line) if block_given?
              next
            end

            committed_line = committed[reference_id]
            tax_included =
              if committed_line
                committed_line["tax_included_in_amount"] ? true : false
              else
                default_tax_included
              end
            sales_key = tax_included ? "amount_including_tax" : "amount_excluding_tax"

            entry = result[reference_id] ||= {
              "sales_amount_refunded" => 0,
              "tax_amount_refunded" => 0,
            }
            entry["sales_amount_refunded"] += line[sales_key].to_i
            entry["tax_amount_refunded"] += line["tax_amount"].to_i
          end
        end
      end

      private

      # @return [Array(Integer, Integer)] remaining refundable [sales, tax]
      def remaining_for_line(committed_line, refunded_line)
        refunded_line ||= {}
        sales = refundable_sales(committed_line) +
          refunded_line.fetch("sales_amount_refunded", 0)
        tax = committed_line.fetch("tax_amount", 0) +
          refunded_line.fetch("tax_amount_refunded", 0)
        [[sales, 0].max, [tax, 0].max]
      end

      # The committed amount Numeral caps this line's refunds against
      # (thomas `getRefundSalesAmount`): gross for tax-inclusive purchases,
      # net otherwise. Inclusive snapshots written before
      # `amount_including_tax` was recorded reconstruct it as net + tax.
      def refundable_sales(committed_line)
        unless committed_line["tax_included_in_amount"]
          return committed_line.fetch("amount_excluding_tax", 0)
        end

        committed_line.fetch("amount_including_tax") do
          committed_line.fetch("amount_excluding_tax", 0) +
            committed_line.fetch("tax_amount", 0)
        end
      end

      def deep_copy(hash)
        hash.transform_values(&:dup)
      end
    end
  end
end
