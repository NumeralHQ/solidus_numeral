# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module SolidusNumeral
  # Minor-unit (cents) conversion helpers. The Numeral API takes and returns
  # integer minor units; the currency exponent comes from the money gem (a
  # solidus_core dependency, via Spree::Money) so zero-decimal currencies such
  # as JPY are handled correctly.
  module Money
    DEFAULT_EXPONENT = 2

    class << self
      # @param amount [BigDecimal, Numeric] amount in major units
      # @return [Integer] amount in minor units, rounded half-up
      def to_minor_units(amount, currency)
        (amount.to_d * subunit_factor(currency)).round.to_i
      end

      # @param minor [Integer] amount in minor units
      # @return [BigDecimal] amount in major units
      def from_minor_units(minor, currency)
        minor.to_d / subunit_factor(currency)
      end

      # Per-unit amount in minor units for a line: total divided across the
      # quantity and rounded to an integer. This matches every existing
      # Numeral integration (Adobe Commerce, BigCommerce, Business Central):
      # divide-and-round, keep the real quantity, and accept up to
      # quantity/2 cents of drift on discounted lines.
      def per_unit_minor_units(total:, quantity:, currency:)
        return 0 if quantity.to_i <= 0

        (to_minor_units(total, currency).to_d / quantity.to_i).round.to_i
      end

      def subunit_factor(currency)
        10**exponent(currency)
      end

      def exponent(currency)
        return DEFAULT_EXPONENT unless defined?(::Money::Currency)

        ::Money::Currency.new(currency.to_s.downcase).exponent.to_i
      rescue StandardError
        DEFAULT_EXPONENT
      end
    end
  end
end
