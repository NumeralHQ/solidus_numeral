# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::CancelOrderJob do
  let(:api) { double("ApiClient") }
  let(:order) { double("Order", number: "R1") }

  before do
    allow(SolidusNumeral).to receive(:api_client).and_return(api)
    allow(SolidusNumeral::SyncLog).to receive(:record)
    allow(SolidusNumeral::OrderTransaction).to receive(:with_locked_row)
      .with(order, create: true).and_yield(row)
  end

  context "with a pending (never committed) row" do
    let(:row) { double("OrderTransaction", committed?: false, voided?: false) }

    it "marks the row voided so a late commit is durably blocked" do
      expect(row).to receive(:update!).with(state: "voided")

      described_class.new.perform(order)

      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "void", error_message: /block a late commit/)
      )
    end
  end

  context "with an already-voided row" do
    let(:row) { double("OrderTransaction", committed?: false, voided?: true) }

    it "does nothing" do
      described_class.new.perform(order)

      expect(SolidusNumeral::SyncLog).not_to have_received(:record)
    end
  end

  context "with a committed row" do
    let(:row) do
      double(
        "OrderTransaction",
        committed?: true,
        voided?: false,
        numeral_transaction_id: "tr_1",
        committed_snapshot: {
          "101" => {
            "amount_excluding_tax" => 10_000,
            "amount_including_tax" => 10_000,
            "tax_amount" => 800,
            "quantity" => 2,
            "tax_included_in_amount" => false,
          },
        },
        refunded_snapshot: refunded,
        reconcile_refunds_from_server!: nil
      )
    end

    context "with no refunds yet" do
      let(:refunded) { {} }

      it "issues a full refund" do
        allow(api).to receive(:create_refund)
          .with(transaction_id: "tr_1", type: "full")
          .and_return("id" => "ref_1")
        expect(row).to receive(:update!).with(state: "voided")

        described_class.new.perform(order)
      end
    end

    context "with partial refunds already recorded" do
      let(:refunded) do
        { "101" => { "sales_amount_refunded" => -4_000, "tax_amount_refunded" => -320 } }
      end

      it "refunds the remaining headroom as a partial refund" do
        expect(api).to receive(:create_refund).with(
          transaction_id: "tr_1",
          type: "partial",
          line_items: [
            {
              reference_line_item_id: "101",
              sales_amount_refunded: -6_000,
              tax_amount_refunded: -480,
              quantity: 2,
            },
          ]
        ).and_return("id" => "ref_2")
        expect(row).to receive(:record_refund_lines!)
        expect(row).to receive(:update!).with(state: "voided")

        described_class.new.perform(order)
      end
    end
  end

  context "when a previous attempt's full refund landed but the response was lost" do
    # Real row (save!/update! stubbed) so reconciliation and the
    # remaining-headroom math actually run. Without reconciliation this retry
    # would re-send the full refund, Numeral would reject it ("Refund cannot
    # be greater than the original amount"), and the job would fail forever.
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
      allow(instance).to receive(:update!)
      instance
    end

    it "marks the row voided on retry instead of re-sending the full refund" do
      server_refunds = []
      allow(api).to receive(:get_transaction_refunds).with("tr_1") do
        { "refunds" => server_refunds.dup }
      end

      # The POST reaches Numeral (the refund IS recorded server-side) but the
      # response never arrives.
      expect(api).to receive(:create_refund)
        .with(transaction_id: "tr_1", type: "full")
        .once do
          server_refunds << {
            "id" => "ref_tr_1",
            "line_items" => [
              {
                "product" => { "reference_line_item_id" => "101" },
                "amount_excluding_tax" => -10_000,
                "amount_including_tax" => -10_800,
                "tax_amount" => -800,
                "quantity" => 2,
              },
            ],
          }
          raise Net::ReadTimeout
        end

      expect { described_class.new.perform(order) }.to raise_error(Net::ReadTimeout)

      # ActiveJob-backend retry: reconciliation shows all headroom consumed,
      # so the row is voided and logged as success without another POST.
      described_class.new.perform(order)

      expect(row).to have_received(:update!).with(state: "voided")
      expect(SolidusNumeral::SyncLog).to have_received(:record).with(
        hash_including(action: "void", status: :success)
      )
    end
  end
end
