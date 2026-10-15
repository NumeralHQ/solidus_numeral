# frozen_string_literal: true

require "digest"
require "json"

module SolidusNumeral
  # Rails.cache access for calculation responses.
  #
  # Two entries per calculation:
  # - A REQUEST-KEYED entry (the cache key is a digest of the serialized
  #   calculation request payload, the solidus_taxjar pattern): identical order
  #   states share one API call, and any change to lines/address/discounts
  #   busts the cache naturally.
  # - An ORDER-KEYED pointer to the latest entry for the order, so
  #   CommitTransactionJob can reuse the checkout-time calculation (id,
  #   expires_at, per-line amounts) without re-deriving the request key.
  #
  # Entries are `{"request" => <payload hash>, "response" => <parsed body>}`.
  module CalculationCache
    NAMESPACE = "solidus_numeral/calculation"

    class << self
      # @param payload [Hash] calculation request payload
      # @yieldreturn [Hash] cache entry to store on miss
      # @return [Hash] the cached or freshly-built entry
      def fetch(payload)
        Rails.cache.fetch(request_key(payload), expires_in: cache_duration) do
          yield
        end
      end

      def write_latest_for_order(order, entry)
        Rails.cache.write(order_key(order), entry, expires_in: cache_duration)
      end

      # @return [Hash, nil] the latest `{"request", "response"}` entry
      def read_latest_for_order(order)
        Rails.cache.read(order_key(order))
      end

      def request_key(payload)
        "#{NAMESPACE}/#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
      end

      def order_key(order)
        "#{NAMESPACE}/latest/order/#{order.id}"
      end

      private

      def cache_duration
        SolidusNumeral.config.cache_duration
      end
    end
  end
end
