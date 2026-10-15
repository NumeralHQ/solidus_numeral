# frozen_string_literal: true

module SolidusNumeral
  # Syncs a Spree user to Numeral's customer records (POST /tax/customers).
  #
  # Customer sync is exemption-driven: Numeral resolves exemptions from the
  # customer record (`is_tax_exempt`, ECM certificates), so only users whose
  # exemption flag is managed in the admin UI need a customer record. Once
  # synced, calculations for the user include `customer.id`.
  class SyncCustomerJob < ApplicationJob
    def perform(user_id)
      return unless numeral_enabled?

      user = ::Spree.user_class.find(user_id)

      customer =
        if user.numeral_customer_id.present?
          update_customer(user)
        else
          create_or_adopt_customer(user)
        end

      # update_columns: a callback-triggered save here could re-enqueue this
      # job and loop.
      user.update_columns(
        numeral_customer_id: customer["id"],
        numeral_customer_synced_at: Time.current
      )

      SyncLog.record(
        action: "customer_sync", status: :success, numeral_id: customer["id"]
      )
    rescue ApiError => exception
      SyncLog.record(
        action: "customer_sync", status: :error,
        error_message: "user #{user_id}: #{exception.error_code}: #{exception.message}"
      )
      raise
    end

    private

    def create_or_adopt_customer(user)
      api.create_customer(
        reference_customer_id: user.id.to_s,
        email: user.email,
        is_tax_exempt: user.numeral_tax_exempt
      )
    rescue ApiError => exception
      raise unless exception.duplicate_customer?

      # A customer with this EMAIL or reference id already exists (e.g. a
      # previous attempt whose response was lost, or a customer created
      # outside the gem); adopt and update it.
      api.update_customer(
        customer_id: existing_customer_id(exception, user),
        email: user.email,
        is_tax_exempt: user.numeral_tax_exempt
      )
    end

    # Numeral flags duplicates on email OR reference id and puts the existing
    # customer's id in the error's error_meta - the only handle we have for
    # email-only duplicates (whose reference id is different or absent).
    # Prefer it; fall back to the reference-id lookup when the error body
    # carried no meta (the 2026-01-01+ standard error format omits it). An
    # email-only duplicate without meta then 404s here, failing the job
    # loudly instead of silently adopting the wrong customer.
    def existing_customer_id(exception, user)
      meta_id = exception.error_meta && exception.error_meta["id"]
      return meta_id if meta_id.present?

      api.get_customer_by_reference(user.id.to_s).fetch("id")
    end

    def update_customer(user)
      api.update_customer(
        customer_id: user.numeral_customer_id,
        email: user.email,
        is_tax_exempt: user.numeral_tax_exempt
      )
    end
  end
end
