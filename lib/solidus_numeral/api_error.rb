# frozen_string_literal: true

module SolidusNumeral
  # Raised for any non-2xx response from the Numeral API.
  #
  # On API version 2026-01-01+ error bodies use the standard format
  # `{"code": <http status>, "type": "<ERROR_CODE>", "message": "..."}`. The
  # legacy `{"error": {"error_code": ..., "error_message": ...}}` envelope is
  # parsed as a fallback.
  class ApiError < StandardError
    # HTTP status of the response.
    attr_reader :status
    # Machine-readable error code, downcased (e.g. "calculation_expired").
    attr_reader :error_code
    # Structured error metadata, when the body carries any (e.g. the
    # duplicate_customer error's `error_meta.id` of the existing customer).
    # nil when absent - the 2026-01-01+ standard error format currently
    # serializes only code/type/message.
    attr_reader :error_meta
    # Raw response body, for logging.
    attr_reader :body

    def initialize(message, status:, error_code: nil, error_meta: nil, body: nil)
      super(message)
      @status = status
      @error_code = error_code.to_s.downcase.presence
      @error_meta = error_meta.is_a?(Hash) ? error_meta : nil
      @body = body
    end

    def self.from_response(status:, body:)
      parsed =
        begin
          body.present? ? JSON.parse(body) : {}
        rescue JSON::ParserError
          {}
        end

      error_code, message, error_meta =
        if parsed.key?("type")
          # 2026-01-01+ standard error format. error_meta is not part of the
          # format today, but pick it up if the API starts including it.
          [parsed["type"], parsed["message"], parsed["error_meta"]]
        elsif parsed["error"].is_a?(Hash)
          # Legacy error envelope.
          [
            parsed["error"]["error_code"],
            parsed["error"]["error_message"],
            parsed["error"]["error_meta"],
          ]
        else
          [nil, nil, nil]
        end

      new(
        message.presence || "Numeral API request failed with status #{status}",
        status: status,
        error_code: error_code,
        error_meta: error_meta,
        body: body
      )
    end

    def calculation_expired?
      error_code == "calculation_expired"
    end

    def transaction_already_exists?
      error_code == "transaction_already_exists"
    end

    def duplicate_reference_order_id?
      error_code == "reference_order_id_already_exists"
    end

    def duplicate_product?
      error_code == "duplicate_product"
    end

    def duplicate_customer?
      error_code == "duplicate_customer"
    end

    def invalid_tax_code?
      error_code == "invalid_tax_code"
    end
  end
end
