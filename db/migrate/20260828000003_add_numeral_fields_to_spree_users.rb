# frozen_string_literal: true

class AddNumeralFieldsToSpreeUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_users, :numeral_tax_exempt, :boolean, null: false, default: false
    add_column :spree_users, :numeral_customer_synced_at, :datetime
    add_column :spree_users, :numeral_customer_id, :string
    add_column :spree_users, :numeral_vat_id, :string
  end
end
