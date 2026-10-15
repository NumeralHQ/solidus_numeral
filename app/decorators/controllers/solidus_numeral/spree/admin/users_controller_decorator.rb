# frozen_string_literal: true

module SolidusNumeral
  module Spree
    module Admin
      # Adds a per-user "Numeral information" screen to the admin
      # (GET/PUT /admin/users/:id/numeral_information) for managing the tax
      # exemption flag and VAT id - the solidus_avatax_certified per-user
      # pattern, minus the Deface tab override (the screen is linked from the
      # README instead of injected into the user tabs, so no markup override
      # can break across admin redesigns).
      module UsersControllerDecorator
        def numeral_information
          if request.put?
            exempt_before = @user.numeral_tax_exempt

            if @user.update(numeral_user_params)
              flash.now[:success] = t("spree.account_updated", default: "Account updated")

              # Sync when the exemption flag changed (both directions - Numeral
              # must also learn when an exemption is revoked), or when the user
              # was flagged exempt but a previous sync never completed.
              if @user.numeral_tax_exempt != exempt_before ||
                  (@user.numeral_tax_exempt && @user.numeral_customer_synced_at.blank?)
                SolidusNumeral::SyncCustomerJob.perform_later(@user.id)
              end
            end
          end

          render :numeral_information
        end

        private

        def numeral_user_params
          params.require(:user).permit(:numeral_tax_exempt, :numeral_vat_id)
        end

        ::Spree::Admin::UsersController.prepend self
      end
    end
  end
end
