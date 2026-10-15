# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::CommitTransactionJob do
  let(:api) { double("ApiClient") }
  let(:order) do
    double(
      "Order",
      number: "R1",
      completed_at: Time.utc(2026, 1, 2),
      canceled?: false
    )
  end
  let(:row) { double("OrderTransaction", committed?: false, voided?: false) }

  before do
    allow(SolidusNumeral).to receive(:api_client).and_return(api)
    allow(SolidusNumeral::SyncLog).to receive(:record)
    allow(SolidusNumeral::OrderTransaction).to receive(:with_locked_row)
      .with(order, create: true).and_yield(row)
  end

  it "voids the local row instead of committing when the order is canceled" do
    allow(order).to receive(:canceled?).and_return(true)
    expect(row).to receive(:update!).with(state: "voided")

    described_class.new.perform(order)

    expect(SolidusNumeral::SyncLog).to have_received(:record).with(
      hash_including(
        action: "commit",
        status: :error,
        error_message: /canceled before commit/
      )
    )
  end

  it "records the refund-denomination flag and both amounts in the committed snapshot" do
    calculation = {
      "id" => "calc_1",
      "tax_included_in_amount" => true,
      "line_items" => [
        {
          "product" => { "reference_line_item_id" => "101" },
          "amount_excluding_tax" => 10_000,
          "amount_including_tax" => 12_000,
          "tax_amount" => 2_000,
          "quantity" => 2,
        },
      ],
    }
    allow(SolidusNumeral::ApiParams).to receive(:order_params)
      .with(order).and_return({})
    allow(SolidusNumeral::CalculationCache).to receive(:read_latest_for_order)
      .with(order).and_return(nil)
    allow(api).to receive(:create_calculation).and_return(calculation)
    allow(api).to receive(:create_transaction).and_return("id" => "tr_1")
    allow(row).to receive(:refunded_snapshot).and_return({})

    expect(row).to receive(:update!).with(
      hash_including(
        state: "committed",
        numeral_transaction_id: "tr_1",
        committed_line_items: {
          "101" => {
            "amount_excluding_tax" => 10_000,
            "amount_including_tax" => 12_000,
            "tax_amount" => 2_000,
            "quantity" => 2,
            "tax_included_in_amount" => true,
          },
        }
      )
    )

    described_class.new.perform(order)
  end
end
