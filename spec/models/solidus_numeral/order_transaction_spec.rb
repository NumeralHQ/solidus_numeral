# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::OrderTransaction do
  describe "#reconcile_refunds_from_server!" do
    let(:api) { double("ApiClient") }
    let(:logger) { double("Logger", info: nil, warn: nil, error: nil) }
    let(:row) do
      instance = described_class.new(
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

    let(:server_refund) do
      {
        "id" => "ref_tr_1",
        "line_items" => [
          {
            "product" => { "reference_line_item_id" => "101" },
            "amount_excluding_tax" => -4_000,
            "amount_including_tax" => -4_320,
            "tax_amount" => -320,
            "quantity" => 1,
          },
        ],
      }
    end

    before { SolidusNumeral.config.logger = logger }

    it "skips the GET entirely when the row has no Numeral transaction id" do
      row.numeral_transaction_id = nil

      row.reconcile_refunds_from_server!(api)

      expect(row.refunded_snapshot).to eq({})
      expect(row).not_to have_received(:save!)
    end

    it "overwrites a stale local snapshot with server truth and logs the divergence" do
      allow(api).to receive(:get_transaction_refunds).with("tr_1")
        .and_return("refunds" => [server_refund])

      row.reconcile_refunds_from_server!(api)

      expect(row.refunded_snapshot).to eq(
        "101" => { "sales_amount_refunded" => -4_000, "tax_amount_refunded" => -320 }
      )
      expect(row).to have_received(:save!)
      expect(logger).to have_received(:info).with(/diverged/)
    end

    it "does not save when local and server already agree" do
      row.refunded_line_items = {
        "101" => { "sales_amount_refunded" => -4_000, "tax_amount_refunded" => -320 },
      }
      allow(api).to receive(:get_transaction_refunds)
        .and_return("refunds" => [server_refund])

      row.reconcile_refunds_from_server!(api)

      expect(row).not_to have_received(:save!)
      expect(logger).not_to have_received(:info)
    end

    it "warns about and skips refund lines that cannot be attributed to a committed line" do
      server_refund["line_items"].first["product"]["reference_line_item_id"] = ""
      allow(api).to receive(:get_transaction_refunds)
        .and_return("refunds" => [server_refund])

      row.reconcile_refunds_from_server!(api)

      expect(logger).to have_received(:warn).with(/reference_line_item_id/)
      expect(row.refunded_snapshot).to eq({})
    end

    it "lets a failed GET propagate so the calling job retries" do
      allow(api).to receive(:get_transaction_refunds)
        .and_raise(SolidusNumeral::ApiError.new("server error", status: 500))

      expect { row.reconcile_refunds_from_server!(api) }
        .to raise_error(SolidusNumeral::ApiError)
    end
  end
end
