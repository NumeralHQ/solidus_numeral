# frozen_string_literal: true

class CreateSolidusNumeralOrderTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :solidus_numeral_order_transactions do |t|
      t.references :order, null: false, index: { unique: true }
      t.string :numeral_transaction_id
      t.string :numeral_calculation_id
      t.string :state, null: false, default: "pending"
      t.text :committed_line_items
      t.text :refunded_line_items

      t.timestamps
    end

    add_foreign_key :solidus_numeral_order_transactions, :spree_orders, column: :order_id
    add_index :solidus_numeral_order_transactions, :numeral_transaction_id
  end
end
