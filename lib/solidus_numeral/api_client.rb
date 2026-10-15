# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"

module SolidusNumeral
  # Thin Numeral API client on top of Net::HTTP (no runtime HTTP gem
  # dependencies). All endpoints live under the "/tax" path prefix of the
  # configured api_base, and the API version is pinned via the X-API-Version
  # header.
  class ApiClient
    # Pinned API version. 2026-03-01 includes the 2026-01-01 gates (per-unit
    # amounts, raw jurisdiction output, standard error format, country-specific
    # tax ids) plus `default_customer_type`, which lets calculations reference
    # a customer id without 400ing when it is unknown.
    API_VERSION = "2026-03-01"

    PATH_PREFIX = "/tax"

    OPEN_TIMEOUT = 5
    # Calculations sit on the checkout critical path; keep the budget tight.
    CALCULATION_READ_TIMEOUT = 10
    # Ledger operations run from background jobs and can afford to be slower.
    DEFAULT_READ_TIMEOUT = 30

    def initialize(api_key: nil, api_base: nil, logger: nil)
      @api_key = api_key || SolidusNumeral.config.api_key
      @api_base = api_base || SolidusNumeral.config.api_base
      @logger = logger || SolidusNumeral.config.logger

      raise ArgumentError, "SolidusNumeral api_key is not configured" if @api_key.to_s.empty?
    end

    # @param payload [Hash] a calculation request built by ApiParams
    def create_calculation(payload)
      post("/calculations", payload, read_timeout: CALCULATION_READ_TIMEOUT)
    end

    def create_transaction(calculation_id:, reference_order_id:, transaction_processed_at: nil,
      metadata: nil)
      body = {
        calculation_id: calculation_id,
        reference_order_id: reference_order_id,
      }
      body[:transaction_processed_at] = transaction_processed_at if transaction_processed_at
      body[:metadata] = metadata if metadata

      post("/transactions", body)
    end

    def get_transactions(reference_order_id:)
      get("/transactions", query: { reference_order_id: reference_order_id })
    end

    def delete_transaction(transaction_id)
      delete("/transactions/#{CGI.escape(transaction_id)}")
    end

    # @param type [String] "full" or "partial"; line_items only for "partial"
    def create_refund(transaction_id:, type:, line_items: nil, refund_processed_at: nil)
      body = { transaction_id: transaction_id, type: type }
      body[:line_items] = line_items if line_items
      body[:refund_processed_at] = refund_processed_at if refund_processed_at

      post("/refunds", body)
    end

    # Refunds already recorded against a transaction. Used to reconcile the
    # local refunded snapshot with server truth before posting a refund -
    # Numeral has no refund idempotency key, only cumulative capping.
    def get_transaction_refunds(transaction_id)
      get("/transactions/#{CGI.escape(transaction_id)}/refunds")
    end

    def create_product(reference_product_id:, reference_product_name:, product_category:)
      post("/products", {
        reference_product_id: reference_product_id,
        reference_product_name: reference_product_name,
        product_category: product_category,
      })
    end

    def create_customer(email:, reference_customer_id: nil, name: nil, is_tax_exempt: nil)
      body = { email: email }
      body[:reference_customer_id] = reference_customer_id if reference_customer_id
      body[:name] = name if name
      body[:is_tax_exempt] = is_tax_exempt unless is_tax_exempt.nil?

      post("/customers", body)
    end

    # @param customer_id [String] Numeral customer id ("cust_...")
    def update_customer(customer_id:, email: nil, name: nil, is_tax_exempt: nil,
      reference_customer_id: nil)
      body = {}
      body[:email] = email if email
      body[:name] = name if name
      body[:is_tax_exempt] = is_tax_exempt unless is_tax_exempt.nil?
      body[:reference_customer_id] = reference_customer_id if reference_customer_id

      post("/customers/#{CGI.escape(customer_id)}", body)
    end

    # Looks a customer up by the merchant-side reference id (we use the Spree
    # user id).
    def get_customer_by_reference(reference_customer_id)
      get(
        "/customers/#{CGI.escape(reference_customer_id)}",
        query: { id_type: "reference_customer_id" }
      )
    end

    private

    attr_reader :api_key, :api_base, :logger

    def get(path, query: nil, read_timeout: DEFAULT_READ_TIMEOUT)
      request(Net::HTTP::Get, path, query: query, read_timeout: read_timeout)
    end

    def post(path, body, read_timeout: DEFAULT_READ_TIMEOUT)
      request(Net::HTTP::Post, path, body: body, read_timeout: read_timeout)
    end

    def delete(path, read_timeout: DEFAULT_READ_TIMEOUT)
      request(Net::HTTP::Delete, path, read_timeout: read_timeout)
    end

    def request(method_class, path, body: nil, query: nil, read_timeout: DEFAULT_READ_TIMEOUT)
      uri = build_uri(path, query)

      http_request = method_class.new(uri)
      http_request["Authorization"] = "Bearer #{api_key}"
      http_request["Content-Type"] = "application/json"
      http_request["Accept"] = "application/json"
      http_request["X-API-Version"] = API_VERSION
      http_request["User-Agent"] = "solidus_numeral/#{SolidusNumeral::VERSION}"
      http_request.body = JSON.generate(body) if body

      response = build_http(uri, read_timeout).request(http_request)
      handle_response(response)
    end

    def build_uri(path, query)
      uri = URI.parse("#{api_base.to_s.chomp('/')}#{PATH_PREFIX}#{path}")
      uri.query = URI.encode_www_form(query) if query
      uri
    end

    def build_http(uri, read_timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = read_timeout
      http
    end

    def handle_response(response)
      status = response.code.to_i

      unless status.between?(200, 299)
        error = ApiError.from_response(status: status, body: response.body)
        logger.warn(
          "[solidus_numeral] API error #{status} #{error.error_code}: #{error.message}"
        )
        raise error
      end

      return {} if response.body.to_s.empty?

      JSON.parse(response.body)
    end
  end
end
