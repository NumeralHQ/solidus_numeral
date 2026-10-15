# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::ShortShipRefundJob do
  let(:api) { double("ApiClient") }
  let(:order) do
    double(
      "Order",
      number: "R1",
      completed_at: Time.utc(2026, 1, 2),
      canceled?: false
    )
  end

  before do
    allow(SolidusNumeral).to receive(:api_client).and_return(api)
    allow(SolidusNumeral::SyncLog).to receive(:record)
    allow(SolidusNumeral::OrderTransaction).to receive(:with_locked_row)
      .with(order).and_yield(row)
  end

  context "when the commit has not landed yet (no row)" do
    let(:row) { nil }

    it "raises so the job retries instead of dropping the delta" do
      expect { described_class.new.perform(order) }
        .to raise_error(SolidusNumeral::PendingTransactionError)

      expect(SolidusNumeral::SyncLog).not_to have_received(:record)
    end
  end

  context "when the row is still pending" do
    let(:row) { double("OrderTransaction", committed?: false, voided?: false) }

    it "raises so the job retries" do
      expect { described_class.new.perform(order) }
        .to raise_error(SolidusNumeral::PendingTransactionError)
    end

    it "terminally skips when the order never completed" do
      allow(order).to receive(:completed_at).and_return(nil)

      described_class.new.perform(order)

      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "refund", status: :error, error_message: /skipped/)
      )
    end

    it "terminally skips when the order was canceled" do
      allow(order).to receive(:canceled?).and_return(true)

      described_class.new.perform(order)

      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "refund", status: :error, error_message: /skipped/)
      )
    end
  end

  context "when the row is voided" do
    let(:row) { double("OrderTransaction", committed?: false, voided?: true) }

    it "terminally skips" do
      described_class.new.perform(order)

      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(error_message: /already voided/)
      )
    end
  end

  context "when a previous attempt's delta refund landed but the response was lost" do
    # Real row (save! stubbed) so reconciliation and the delta diff actually run.
    let(:row) do
      instance = SolidusNumeral::OrderTransaction.new(
        state: "committed",
        numeral_transaction_id: "tr_1",
        committed_line_items: {
          "101" => {
            "amount_excluding_tax" => 10_000,
            "amount_including_tax" => 10_800,
            "tax_amount" => 800,
            "quantity" => 2,
            "tax_included_in_amount" => false,
          },
        }
      )
      allow(instance).to receive(:save!)
      instance
    end

    it "does not double-POST the delta on retry" do
      # One of two units short-shipped: the line drops from 10000 to 5000.
      allow(SolidusNumeral::RefundParams).to receive(:current_order_lines)
        .with(order).and_return("101" => 5_000)

      server_refunds = []
      allow(api).to receive(:get_transaction_refunds).with("tr_1") do
        { "refunds" => server_refunds.dup }
      end

      # The POST reaches Numeral (the refund IS recorded server-side) but the
      # response never arrives.
      expect(api).to receive(:create_refund).with(
        transaction_id: "tr_1",
        type: "partial",
        line_items: [
          {
            reference_line_item_id: "101",
            sales_amount_refunded: -5_000,
            tax_amount_refunded: -400,
            quantity: 2,
          },
        ]
      ).once do
        server_refunds << {
          "id" => "ref_tr_1",
          "line_items" => [
            {
              "product" => { "reference_line_item_id" => "101" },
              "amount_excluding_tax" => -5_000,
              "amount_including_tax" => -5_400,
              "tax_amount" => -400,
              "quantity" => 2,
            },
          ],
        }
        raise Net::ReadTimeout
      end

      expect { described_class.new.perform(order) }.to raise_error(Net::ReadTimeout)

      # ActiveJob-backend retry: reconciliation adopts the server's refund,
      # the delta diff is now zero, and nothing is re-sent (`.once` above
      # would fail otherwise).
      described_class.new.perform(order)

      expect(row.refunded_snapshot).to eq(
        "101" => { "sales_amount_refunded" => -5_000, "tax_amount_refunded" => -400 }
      )
    end
  end
end
