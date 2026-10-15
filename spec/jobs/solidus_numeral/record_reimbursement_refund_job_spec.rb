# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::RecordReimbursementRefundJob do
  let(:api) { double("ApiClient") }
  let(:order) do
    double(
      "Order",
      number: "R1",
      completed_at: Time.utc(2026, 1, 2),
      canceled?: false
    )
  end
  let(:reimbursement) { double("Reimbursement", number: "RI1", order: order) }

  before do
    allow(SolidusNumeral).to receive(:api_client).and_return(api)
    allow(SolidusNumeral::SyncLog).to receive(:record)
    allow(SolidusNumeral::OrderTransaction).to receive(:with_locked_row)
      .with(order).and_yield(row)
  end

  context "when the commit has not landed yet" do
    let(:row) { nil }

    it "raises so the job retries instead of dropping the refund" do
      expect { described_class.new.perform(reimbursement) }
        .to raise_error(SolidusNumeral::PendingTransactionError)
    end

    it "terminally skips when the order never completed" do
      allow(order).to receive(:completed_at).and_return(nil)

      described_class.new.perform(reimbursement)

      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "refund", status: :error, error_message: /skipped/)
      )
    end
  end

  context "with a committed tax-inclusive row" do
    let(:committed) do
      {
        "101" => {
          "amount_excluding_tax" => 10_000,
          "amount_including_tax" => 12_000,
          "tax_amount" => 2_000,
          "quantity" => 1,
          "tax_included_in_amount" => true,
        },
      }
    end
    let(:row) do
      double(
        "OrderTransaction",
        committed?: true,
        voided?: false,
        numeral_transaction_id: "tr_1",
        committed_snapshot: committed,
        refunded_snapshot: {},
        tax_included_in_amount?: true,
        reconcile_refunds_from_server!: nil
      )
    end

    it "requests reimbursement lines denominated gross and sends the capped refund" do
      # RefundParams receives the row's inclusivity so ReturnItem#amount
      # (which includes the VAT) is sent as-is.
      expect(SolidusNumeral::RefundParams).to receive(:reimbursement_requested_lines)
        .with(reimbursement, tax_included: true)
        .and_return("101" => { "sales" => 12_000, "tax" => 2_000, "quantity" => 1 })
      expect(api).to receive(:create_refund).with(
        transaction_id: "tr_1",
        type: "partial",
        line_items: [
          {
            reference_line_item_id: "101",
            sales_amount_refunded: -12_000,
            tax_amount_refunded: -2_000,
            quantity: 1,
          },
        ]
      ).and_return("id" => "ref_1")
      expect(row).to receive(:record_refund_lines!)

      described_class.new.perform(reimbursement)
    end
  end

  context "when a previous attempt's refund POST landed but the response was lost" do
    # Real row (save! stubbed) so reconciliation and capping actually run.
    let(:row) do
      instance = SolidusNumeral::OrderTransaction.new(
        state: "committed",
        numeral_transaction_id: "tr_1",
        committed_line_items: {
          "101" => {
            "amount_excluding_tax" => 10_000,
            "amount_including_tax" => 10_800,
            "tax_amount" => 800,
            "quantity" => 1,
            "tax_included_in_amount" => false,
          },
        }
      )
      allow(instance).to receive(:save!)
      instance
    end

    it "does not double-POST the refund on retry" do
      server_refunds = []
      allow(api).to receive(:get_transaction_refunds).with("tr_1") do
        { "refunds" => server_refunds.dup }
      end
      allow(SolidusNumeral::RefundParams).to receive(:reimbursement_requested_lines)
        .and_return("101" => { "sales" => 10_000, "tax" => 800, "quantity" => 1 })

      # The POST reaches Numeral (the refund IS recorded server-side) but the
      # response never arrives.
      expect(api).to receive(:create_refund).with(
        transaction_id: "tr_1",
        type: "partial",
        line_items: [
          {
            reference_line_item_id: "101",
            sales_amount_refunded: -10_000,
            tax_amount_refunded: -800,
            quantity: 1,
          },
        ]
      ).once do
        server_refunds << {
          "id" => "ref_tr_1",
          "line_items" => [
            {
              "product" => { "reference_line_item_id" => "101" },
              "amount_excluding_tax" => -10_000,
              "amount_including_tax" => -10_800,
              "tax_amount" => -800,
              "quantity" => 1,
            },
          ],
        }
        raise Net::ReadTimeout
      end

      expect { described_class.new.perform(reimbursement) }
        .to raise_error(Net::ReadTimeout)

      # ActiveJob-backend retry: reconciliation adopts the server's refund,
      # capping leaves nothing to send, and no second POST happens (`.once`
      # above would fail otherwise).
      described_class.new.perform(reimbursement)

      expect(row.refunded_snapshot).to eq(
        "101" => { "sales_amount_refunded" => -10_000, "tax_amount_refunded" => -800 }
      )
      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "refund", error_message: /no refundable amounts/)
      )
    end
  end
end
