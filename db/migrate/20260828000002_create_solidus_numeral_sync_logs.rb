# frozen_string_literal: true

class CreateSolidusNumeralSyncLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :solidus_numeral_sync_logs do |t|
      t.references :order
      t.string :action, null: false
      t.string :status, null: false
      t.string :numeral_id
      t.text :error_message

      t.timestamps
    end

    add_foreign_key :solidus_numeral_sync_logs, :spree_orders, column: :order_id
  end
end
