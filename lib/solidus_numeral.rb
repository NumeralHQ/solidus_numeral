# frozen_string_literal: true

require "solidus_core"
require "solidus_support"

require "solidus_numeral/version"
require "solidus_numeral/configuration"
require "solidus_numeral/api_error"
require "solidus_numeral/api_client"
require "solidus_numeral/money"
require "solidus_numeral/discount_calculator"
require "solidus_numeral/api_params"
require "solidus_numeral/refund_math"
require "solidus_numeral/refund_params"
require "solidus_numeral/calculation_cache"
require "solidus_numeral/engine"

module SolidusNumeral
  class << self
    # @return [SolidusNumeral::Configuration] the singleton configuration
    def configuration
      @configuration ||= Configuration.new
    end
    alias config configuration

    def configure
      yield configuration
    end

    # Discards the current configuration. Intended for test suites.
    def reset_configuration!
      @configuration = Configuration.new
    end

    # @return [SolidusNumeral::ApiClient] a client built from the current configuration
    def api_client
      ApiClient.new
    end

    # ActiveRecord uses this to resolve table names for models under the
    # SolidusNumeral namespace (solidus_numeral_order_transactions, ...).
    def table_name_prefix
      "solidus_numeral_"
    end

    # Registers the extension's event subscribers on Spree::Bus. Idempotent so
    # code reloading in development doesn't stack duplicate subscriptions.
    def subscribe_to_spree_bus
      unsubscribe_from_spree_bus

      @spree_bus_subscriptions = [
        SolidusNumeral::OrderSubscriber.new.subscribe_to(::Spree::Bus),
        SolidusNumeral::ReimbursementSubscriber.new.subscribe_to(::Spree::Bus),
      ].flatten
    end

    def unsubscribe_from_spree_bus
      Array(@spree_bus_subscriptions).each do |subscription|
        ::Spree::Bus.unsubscribe(subscription)
      end
      @spree_bus_subscriptions = nil
    end
  end
end
