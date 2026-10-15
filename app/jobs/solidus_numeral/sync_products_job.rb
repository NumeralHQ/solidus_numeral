# frozen_string_literal: true

module SolidusNumeral
  # Pushes the catalog to Numeral (POST /tax/products) so products show up in
  # the dashboard and can flow through AI categorization / ops review.
  #
  # OPTIONAL: calculations never require pre-synced products - unknown
  # reference_product_ids are auto-created from the line's product_category /
  # fallback_product_category. Run via `bin/rails numeral:sync_products` or
  # enqueue directly.
  #
  # Idempotent: a duplicate-product 400 is treated as success, so re-running
  # after a partial failure is safe.
  class SyncProductsJob < ApplicationJob
    # Keep well under the default 20 req/s API rate limit.
    SLEEP_BETWEEN_REQUESTS = 0.1
    MAX_NAME_LENGTH = 255

    def perform
      return unless numeral_enabled?

      synced = 0
      failed = 0
      seen_skus = Set.new

      # Eager-load everything the loop touches: the variant's own tax
      # category, option values (+ types, for descriptive_name), and the
      # product with its tax category (both fallbacks).
      ::Spree::Variant.includes(
        :tax_category,
        { option_values: :option_type },
        { product: :tax_category }
      ).find_each do |variant|
        sku = variant.sku.to_s
        next if sku.blank?
        next if seen_skus.include?(sku)

        seen_skus << sku

        if sync_variant(variant, sku)
          synced += 1
        else
          failed += 1
        end

        sleep(SLEEP_BETWEEN_REQUESTS)
      end

      summary = "synced #{synced} products"
      summary += ", #{failed} failed (see logs)" if failed.positive?

      SyncLog.record(
        action: "product_sync",
        status: failed.zero? ? :success : :error,
        error_message: summary
      )
    end

    private

    def sync_variant(variant, sku)
      attempt_sync(variant, sku, product_category(variant), retry_on_invalid_tax_code: true)
    end

    # @return [Boolean] whether the product ended up synced
    def attempt_sync(variant, sku, category, retry_on_invalid_tax_code:)
      api.create_product(
        reference_product_id: sku[0, ApiParams::MAX_REFERENCE_PRODUCT_ID_LENGTH],
        reference_product_name: product_name(variant),
        product_category: category
      )
      true
    rescue ApiError => exception
      if exception.duplicate_product?
        true
      elsif exception.invalid_tax_code? && retry_on_invalid_tax_code
        # The merchant mapped this tax category to a code Numeral doesn't
        # recognize; fall back to general merchandise rather than dropping the
        # product, and leave a trail in the logs.
        logger.warn(
          "[solidus_numeral] invalid tax code " \
          "#{variant.tax_category&.tax_code.inspect} for SKU #{sku}; " \
          "syncing as #{ApiParams::GENERAL_MERCHANDISE}"
        )
        attempt_sync(
          variant, sku, ApiParams::GENERAL_MERCHANDISE,
          retry_on_invalid_tax_code: false
        )
      else
        logger.error(
          "[solidus_numeral] failed to sync product #{sku}: " \
          "#{exception.error_code}: #{exception.message}"
        )
        false
      end
    end

    def product_name(variant)
      name = variant.descriptive_name.presence || variant.product&.name.to_s
      name.to_s[0, MAX_NAME_LENGTH].presence || variant.sku.to_s[0, MAX_NAME_LENGTH]
    end

    # Variant tax category falls back to the product's; unmapped categories
    # fall back to GENERAL_MERCHANDISE (same as our other integrations).
    def product_category(variant)
      variant.tax_category&.tax_code.presence || ApiParams::GENERAL_MERCHANDISE
    end
  end
end
