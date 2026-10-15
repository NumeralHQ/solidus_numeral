# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Load the dummy app (created by solidus_dev_support) so Spree classes are
# available. Specs themselves are pure-logic unit tests over stubs - no
# factories, no live HTTP.
require File.expand_path("dummy/config/environment.rb", __dir__).tap { |file|
  # Create the dummy app if it's still missing.
  system "bin/rake extension:test_app" unless File.exist?(file)
}

require "solidus_dev_support/rspec/rails_helper"

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.use_transactional_fixtures = true

  # Every example runs against a fresh, fully-configured SolidusNumeral
  # config so examples can't leak configuration into each other.
  config.before do
    SolidusNumeral.reset_configuration!
    SolidusNumeral.configure do |numeral_config|
      numeral_config.api_key = "sk_test_spec"
      # Avoid touching the DB for the tax-inclusive heuristic in unit specs.
      numeral_config.tax_included_in_price = false
    end
  end

  config.after(:suite) do
    SolidusNumeral.reset_configuration!
  end
end
