# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::RefundMath do
  let(:committed) do
    {
      "101" => { "amount_excluding_tax" => 10_000, "tax_amount" => 800, "quantity" => 2 },
      "shipment-7" => { "amount_excluding_tax" => 1_000, "tax_amount" => 80, "quantity" => 1 },
    }
  end

  # Tax-inclusive (VAT) snapshot: sales amounts are denominated GROSS
  # (amount_including_tax), matching what Numeral caps refunds against.
  let(:inclusive_committed) do
    {
      "101" => {
        "amount_excluding_tax" => 10_000,
        "amount_including_tax" => 12_000,
        "tax_amount" => 2_000,
        "quantity" => 2,
        "tax_included_in_amount" => true,
      },
    }
  end

  describe ".cap_refund_lines" do
    it "converts requested amounts into negative refund line items" do
      requested = { "101" => { "sales" => 5_000, "tax" => 400, "quantity" => 1 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: committed, refunded: {}
      )

      expect(lines).to eq([
        {
          reference_line_item_id: "101",
          sales_amount_refunded: -5_000,
          tax_amount_refunded: -400,
          quantity: 1,
        },
      ])
    end

    it "caps amounts at the committed snapshot, not the requested amount" do
      # Rounding drift guard: Solidus's own totals can exceed what Numeral
      # stored by a few cents on discounted lines.
      requested = { "101" => { "sales" => 10_003, "tax" => 805, "quantity" => 2 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: committed, refunded: {}
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-10_000)
      expect(lines.first[:tax_amount_refunded]).to eq(-800)
    end

    it "caps against remaining headroom when refunds were already recorded" do
      refunded = {
        "101" => { "sales_amount_refunded" => -9_500, "tax_amount_refunded" => -750 },
      }
      requested = { "101" => { "sales" => 2_000, "tax" => 100, "quantity" => 1 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: committed, refunded: refunded
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-500)
      expect(lines.first[:tax_amount_refunded]).to eq(-50)
    end

    it "drops lines with no sales headroom left (the API requires sales < 0)" do
      refunded = {
        "101" => { "sales_amount_refunded" => -10_000, "tax_amount_refunded" => -800 },
      }
      requested = { "101" => { "sales" => 100, "tax" => 8, "quantity" => 1 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: committed, refunded: refunded
      )

      expect(lines).to be_empty
    end

    it "drops lines not present in the committed snapshot" do
      requested = { "999" => { "sales" => 100, "tax" => 8, "quantity" => 1 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: committed, refunded: {}
      )

      expect(lines).to be_empty
    end

    it "caps tax-inclusive lines against the GROSS committed amount" do
      # 12000 gross requested against 12000 gross committed: nothing to cap.
      # A net-denominated cap (10000) would wrongly shave off the VAT.
      requested = { "101" => { "sales" => 12_000, "tax" => 2_000, "quantity" => 2 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: inclusive_committed, refunded: {}
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-12_000)
      expect(lines.first[:tax_amount_refunded]).to eq(-2_000)
    end

    it "tracks tax-inclusive headroom in gross terms" do
      refunded = {
        "101" => { "sales_amount_refunded" => -9_000, "tax_amount_refunded" => -1_500 },
      }
      requested = { "101" => { "sales" => 6_000, "tax" => 1_000, "quantity" => 1 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: inclusive_committed, refunded: refunded
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-3_000)
      expect(lines.first[:tax_amount_refunded]).to eq(-500)
    end

    it "reconstructs gross headroom for inclusive snapshots missing amount_including_tax" do
      legacy_committed = {
        "101" => {
          "amount_excluding_tax" => 10_000,
          "tax_amount" => 2_000,
          "quantity" => 2,
          "tax_included_in_amount" => true,
        },
      }
      requested = { "101" => { "sales" => 12_000, "tax" => 2_000, "quantity" => 2 } }

      lines = described_class.cap_refund_lines(
        requested: requested, committed: legacy_committed, refunded: {}
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-12_000)
    end
  end

  describe ".remaining_refund_lines" do
    it "returns refund lines for the full committed amounts when nothing was refunded" do
      lines = described_class.remaining_refund_lines(committed: committed, refunded: {})

      expect(lines).to contain_exactly(
        {
          reference_line_item_id: "101",
          sales_amount_refunded: -10_000,
          tax_amount_refunded: -800,
          quantity: 2,
        },
        {
          reference_line_item_id: "shipment-7",
          sales_amount_refunded: -1_000,
          tax_amount_refunded: -80,
          quantity: 1,
        }
      )
    end

    it "subtracts cumulative refunds and drops exhausted lines" do
      refunded = {
        "101" => { "sales_amount_refunded" => -4_000, "tax_amount_refunded" => -320 },
        "shipment-7" => { "sales_amount_refunded" => -1_000, "tax_amount_refunded" => -80 },
      }

      lines = described_class.remaining_refund_lines(committed: committed, refunded: refunded)

      expect(lines).to eq([
        {
          reference_line_item_id: "101",
          sales_amount_refunded: -6_000,
          tax_amount_refunded: -480,
          quantity: 2,
        },
      ])
    end

    it "denominates tax-inclusive lines in gross" do
      lines = described_class.remaining_refund_lines(
        committed: inclusive_committed, refunded: {}
      )

      expect(lines.first[:sales_amount_refunded]).to eq(-12_000)
      expect(lines.first[:tax_amount_refunded]).to eq(-2_000)
    end
  end

  describe ".short_ship_deltas" do
    it "requests the decrease with tax prorated at the committed rate" do
      # One of two units short-shipped: line drops from 10000 to 5000.
      current = { "101" => 5_000, "shipment-7" => 1_000 }

      deltas = described_class.short_ship_deltas(
        committed: committed, refunded: {}, current: current
      )

      expect(deltas).to eq(
        "101" => { "sales" => 5_000, "tax" => 400, "quantity" => 2 }
      )
    end

    it "treats missing lines as fully removed" do
      current = { "101" => 10_000 }

      deltas = described_class.short_ship_deltas(
        committed: committed, refunded: {}, current: current
      )

      expect(deltas).to eq(
        "shipment-7" => { "sales" => 1_000, "tax" => 80, "quantity" => 1 }
      )
    end

    it "is idempotent: diffing against already-refunded state yields nothing" do
      current = { "101" => 5_000, "shipment-7" => 1_000 }
      refunded = {
        "101" => { "sales_amount_refunded" => -5_000, "tax_amount_refunded" => -400 },
      }

      deltas = described_class.short_ship_deltas(
        committed: committed, refunded: refunded, current: current
      )

      expect(deltas).to be_empty
    end

    it "never prorates more tax than the remaining tax headroom" do
      refunded = {
        "101" => { "sales_amount_refunded" => -1_000, "tax_amount_refunded" => -790 },
      }
      current = { "101" => 0, "shipment-7" => 1_000 }

      deltas = described_class.short_ship_deltas(
        committed: committed, refunded: refunded, current: current
      )

      expect(deltas["101"]["sales"]).to eq(9_000)
      expect(deltas["101"]["tax"]).to eq(10) # capped at remaining tax
    end

    it "diffs tax-inclusive lines in gross and prorates tax on the gross base" do
      # One of two units short-shipped: current gross drops 12000 -> 6000.
      current = { "101" => 6_000 }

      deltas = described_class.short_ship_deltas(
        committed: inclusive_committed, refunded: {}, current: current
      )

      # 6000/12000 of the committed 2000 tax.
      expect(deltas).to eq(
        "101" => { "sales" => 6_000, "tax" => 1_000, "quantity" => 2 }
      )
    end
  end

  describe ".refunded_from_server" do
    # A refund line item as GET /tax/transactions/:id/refunds returns it:
    # negative totals, echoing the original line's reference_line_item_id.
    def server_line(reference_id, excl:, incl:, tax:, quantity: 1)
      {
        "line_item_id" => "li_refund",
        "product" => { "reference_line_item_id" => reference_id },
        "amount_excluding_tax" => excl,
        "amount_including_tax" => incl,
        "tax_amount" => tax,
        "quantity" => quantity,
      }
    end

    it "aggregates negative totals per line across refunds, denominated net for exclusive lines" do
      refunds = [
        {
          "id" => "ref_tr_1",
          "line_items" => [server_line("101", excl: -2_000, incl: -2_160, tax: -160)],
        },
        {
          "id" => "ref_tr_2",
          "line_items" => [
            server_line("101", excl: -1_000, incl: -1_080, tax: -80),
            server_line("shipment-7", excl: -500, incl: -540, tax: -40),
          ],
        },
      ]

      result = described_class.refunded_from_server(refunds: refunds, committed: committed)

      expect(result).to eq(
        "101" => { "sales_amount_refunded" => -3_000, "tax_amount_refunded" => -240 },
        "shipment-7" => { "sales_amount_refunded" => -500, "tax_amount_refunded" => -40 }
      )
    end

    it "denominates tax-inclusive lines gross (amount_including_tax)" do
      refunds = [
        {
          "id" => "ref_tr_1",
          "line_items" => [server_line("101", excl: -5_000, incl: -6_000, tax: -1_000)],
        },
      ]

      result = described_class.refunded_from_server(
        refunds: refunds, committed: inclusive_committed
      )

      expect(result["101"]).to eq(
        "sales_amount_refunded" => -6_000, "tax_amount_refunded" => -1_000
      )
    end

    it "makes a server-side full refund consume all remaining headroom" do
      # Numeral represents a full refund as one refund whose line items invert
      # every committed line (the GET response carries no refund_type).
      refunds = [
        {
          "id" => "ref_tr_1",
          "line_items" => [
            server_line("101", excl: -10_000, incl: -10_800, tax: -800, quantity: 2),
            server_line("shipment-7", excl: -1_000, incl: -1_080, tax: -80),
          ],
        },
      ]

      refunded = described_class.refunded_from_server(refunds: refunds, committed: committed)

      expect(
        described_class.remaining_refund_lines(committed: committed, refunded: refunded)
      ).to be_empty
    end

    it "yields lines without a reference_line_item_id and skips them" do
      orphan = server_line("", excl: -100, incl: -108, tax: -8)
      refunds = [{ "id" => "ref_tr_1", "line_items" => [orphan] }]

      yielded = []
      result = described_class.refunded_from_server(
        refunds: refunds, committed: committed
      ) { |refund, line| yielded << [refund["id"], line] }

      expect(result).to eq({})
      expect(yielded).to eq([["ref_tr_1", orphan]])
    end

    it "keeps lines unknown to the committed snapshot, denominated by default_tax_included" do
      refunds = [
        {
          "id" => "ref_tr_1",
          "line_items" => [server_line("999", excl: -500, incl: -600, tax: -100)],
        },
      ]

      result = described_class.refunded_from_server(
        refunds: refunds, committed: committed, default_tax_included: true
      )

      expect(result["999"]).to eq(
        "sales_amount_refunded" => -600, "tax_amount_refunded" => -100
      )
    end
  end

  describe ".accumulate" do
    it "folds refund line items into the cumulative hash without mutating it" do
      refunded = {
        "101" => { "sales_amount_refunded" => -1_000, "tax_amount_refunded" => -80 },
      }
      lines = [
        {
          reference_line_item_id: "101",
          sales_amount_refunded: -500,
          tax_amount_refunded: -40,
          quantity: 1,
        },
        {
          reference_line_item_id: "shipment-7",
          sales_amount_refunded: -1_000,
          tax_amount_refunded: -80,
          quantity: 1,
        },
      ]

      result = described_class.accumulate(refunded, lines)

      expect(result).to eq(
        "101" => { "sales_amount_refunded" => -1_500, "tax_amount_refunded" => -120 },
        "shipment-7" => { "sales_amount_refunded" => -1_000, "tax_amount_refunded" => -80 }
      )
      expect(refunded["101"]["sales_amount_refunded"]).to eq(-1_000)
    end
  end
end
