# frozen_string_literal: true

SolidusNumeral.configure do |config|
  # Your secret API key from the Numeral dashboard. Use an sk_test_ key for
  # testing and an sk_live_ key in production.
  config.api_key = ENV["NUMERAL_API_KEY"]
end

Spree.config do |config|
  config.tax_calculator_class = "SolidusNumeral::TaxCalculator"
  config.shipping_rate_tax_calculator_class = "SolidusNumeral::ShippingRateTaxCalculator"
end
