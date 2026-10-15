# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::ApiClient do
  subject(:client) do
    described_class.new(api_key: "sk_test_abc", api_base: "https://api.example.com")
  end

  let(:http) { instance_double(Net::HTTP) }
  let(:captured_requests) { [] }

  def stub_response(code:, body:)
    response = double("Net::HTTPResponse", code: code.to_s, body: body)
    allow(client).to receive(:build_http).and_return(http)
    allow(http).to receive(:request) { |request|
      captured_requests << request
      response
    }
  end

  describe "request construction" do
    before { stub_response(code: 200, body: '{"id":"calc_1"}') }

    it "POSTs calculations under the /tax prefix with pinned headers" do
      result = client.create_calculation({ foo: "bar" })

      request = captured_requests.last
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/tax/calculations")
      expect(request["Authorization"]).to eq("Bearer sk_test_abc")
      expect(request["Content-Type"]).to eq("application/json")
      expect(request["X-API-Version"]).to eq("2026-03-01")
      expect(JSON.parse(request.body)).to eq("foo" => "bar")
      expect(result).to eq("id" => "calc_1")
    end

    it "builds the transaction body with only the provided optional fields" do
      client.create_transaction(
        calculation_id: "calc_1",
        reference_order_id: "R1",
        transaction_processed_at: 1_770_000_000
      )

      body = JSON.parse(captured_requests.last.body)
      expect(body).to eq(
        "calculation_id" => "calc_1",
        "reference_order_id" => "R1",
        "transaction_processed_at" => 1_770_000_000
      )
    end

    it "GETs transactions by reference order id via query string" do
      client.get_transactions(reference_order_id: "R 1/2")

      request = captured_requests.last
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/tax/transactions?reference_order_id=R+1%2F2")
    end

    it "DELETEs transactions by id" do
      client.delete_transaction("tr_123")

      request = captured_requests.last
      expect(request).to be_a(Net::HTTP::Delete)
      expect(request.path).to eq("/tax/transactions/tr_123")
    end

    it "omits line_items from full refunds" do
      client.create_refund(transaction_id: "tr_123", type: "full")

      expect(JSON.parse(captured_requests.last.body)).to eq(
        "transaction_id" => "tr_123", "type" => "full"
      )
    end

    it "includes line_items on partial refunds" do
      client.create_refund(
        transaction_id: "tr_123",
        type: "partial",
        line_items: [
          {
            reference_line_item_id: "101",
            sales_amount_refunded: -500,
            tax_amount_refunded: -40,
            quantity: 1,
          },
        ]
      )

      body = JSON.parse(captured_requests.last.body)
      expect(body["type"]).to eq("partial")
      expect(body["line_items"]).to eq([
        {
          "reference_line_item_id" => "101",
          "sales_amount_refunded" => -500,
          "tax_amount_refunded" => -40,
          "quantity" => 1,
        },
      ])
    end

    it "GETs a transaction's refunds by transaction id" do
      client.get_transaction_refunds("ref tr/1")

      request = captured_requests.last
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/tax/transactions/ref+tr%2F1/refunds")
    end

    it "looks customers up by reference id with id_type" do
      client.get_customer_by_reference("42")

      expect(captured_requests.last.path)
        .to eq("/tax/customers/42?id_type=reference_customer_id")
    end
  end

  describe "error handling" do
    it "raises ApiError parsed from the 2026-01-01+ standard error format" do
      stub_response(
        code: 400,
        body: '{"code":400,"type":"CALCULATION_EXPIRED","message":"Calculation has expired."}'
      )

      expect { client.create_transaction(calculation_id: "c", reference_order_id: "r") }
        .to raise_error(SolidusNumeral::ApiError) { |error|
          expect(error.status).to eq(400)
          expect(error.error_code).to eq("calculation_expired")
          expect(error.calculation_expired?).to be(true)
          expect(error.message).to eq("Calculation has expired.")
        }
    end

    it "parses the legacy error envelope as a fallback, including error_meta" do
      stub_response(
        code: 400,
        body: '{"error":{"error_code":"duplicate_customer",' \
          '"error_message":"Customer already exists.",' \
          '"error_meta":{"id":"cust_1","email":"a@b.c"}}}'
      )

      expect { client.create_customer(email: "a@b.c") }
        .to raise_error(SolidusNumeral::ApiError) { |error|
          expect(error.duplicate_customer?).to be(true)
          expect(error.error_meta).to eq("id" => "cust_1", "email" => "a@b.c")
        }
    end

    it "picks error_meta up from the standard format when present" do
      stub_response(
        code: 400,
        body: '{"code":400,"type":"DUPLICATE_CUSTOMER",' \
          '"message":"Customer already exists.","error_meta":{"id":"cust_2"}}'
      )

      expect { client.create_customer(email: "a@b.c") }
        .to raise_error(SolidusNumeral::ApiError) { |error|
          expect(error.error_meta).to eq("id" => "cust_2")
        }
    end

    it "leaves error_meta nil when the body carries none" do
      stub_response(
        code: 400,
        body: '{"code":400,"type":"DUPLICATE_CUSTOMER","message":"Customer already exists."}'
      )

      expect { client.create_customer(email: "a@b.c") }
        .to raise_error(SolidusNumeral::ApiError) { |error|
          expect(error.error_meta).to be_nil
        }
    end

    it "raises a generic ApiError for unparseable bodies" do
      stub_response(code: 500, body: "<html>bad gateway</html>")

      expect { client.get_transactions(reference_order_id: "R1") }
        .to raise_error(SolidusNumeral::ApiError) { |error|
          expect(error.status).to eq(500)
          expect(error.error_code).to be_nil
        }
    end
  end

  it "requires an api_key" do
    SolidusNumeral.config.api_key = nil

    expect { described_class.new }.to raise_error(ArgumentError, /api_key/)
  end
end
