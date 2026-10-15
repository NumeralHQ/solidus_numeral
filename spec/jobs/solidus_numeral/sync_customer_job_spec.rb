# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusNumeral::SyncCustomerJob do
  let(:api) { double("ApiClient") }
  let(:user) do
    double(
      "User",
      id: 42,
      email: "buyer@example.com",
      numeral_customer_id: nil,
      numeral_tax_exempt: true,
      update_columns: true
    )
  end
  let(:user_class) { double("UserClass", find: user) }

  let(:duplicate_error) do
    SolidusNumeral::ApiError.new(
      "Customer already exists.",
      status: 400,
      error_code: "duplicate_customer",
      error_meta: error_meta
    )
  end

  before do
    allow(SolidusNumeral).to receive(:api_client).and_return(api)
    allow(SolidusNumeral::SyncLog).to receive(:record)
    allow(::Spree).to receive(:user_class).and_return(user_class)
    allow(api).to receive(:create_customer).and_raise(duplicate_error)
  end

  context "when the duplicate error carries error_meta" do
    let(:error_meta) { { "id" => "cust_9", "email" => "buyer@example.com" } }

    it "adopts the existing customer by the id in error_meta" do
      # An email-only duplicate has a different (or no) reference id, so the
      # reference lookup must not be the primary recovery path.
      expect(api).not_to receive(:get_customer_by_reference)
      expect(api).to receive(:update_customer).with(
        customer_id: "cust_9",
        email: "buyer@example.com",
        is_tax_exempt: true
      ).and_return("id" => "cust_9")

      described_class.new.perform(42)

      expect(user).to have_received(:update_columns).with(
        hash_including(numeral_customer_id: "cust_9")
      )
    end
  end

  context "when the error body carried no error_meta" do
    let(:error_meta) { nil }

    it "falls back to the reference-id lookup" do
      expect(api).to receive(:get_customer_by_reference).with("42")
        .and_return("id" => "cust_5")
      expect(api).to receive(:update_customer).with(
        hash_including(customer_id: "cust_5")
      ).and_return("id" => "cust_5")

      described_class.new.perform(42)
    end
  end
end
