# frozen_string_literal: true

module SolidusNumeral
  class Engine < Rails::Engine
    isolate_namespace ::Spree
    engine_name "solidus_numeral"

    include SolidusSupport::EngineExtensions

    config.generators do |generator|
      generator.test_framework :rspec
    end

    initializer "solidus_numeral.spree_bus" do |app|
      app.reloader.to_prepare do
        SolidusNumeral.subscribe_to_spree_bus
      end
    end

    # One-time boot warning: an enabled extension without an api_key returns
    # zero tax on every calculation (the calculator also warns at runtime,
    # see TaxCalculator.warn_not_calculating).
    initializer "solidus_numeral.missing_api_key_warning" do |app|
      app.config.after_initialize do
        if SolidusNumeral.config.enabled && SolidusNumeral.config.api_key.blank?
          SolidusNumeral.config.logger.warn(
            "[solidus_numeral] the extension is enabled but api_key is " \
            "blank - every tax calculation will return zero tax until an " \
            "api_key is configured"
          )
        end
      end
    end
  end
end
