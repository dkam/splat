# frozen_string_literal: true

module Logs
  # Single place to unwrap a stored log-attribute value to a scalar, whatever
  # the source shape:
  #   * Sentry  — {"value" => x, "type" => "string"}
  #   * OTLP    — an AnyValue: {"stringValue"|"intValue"|"boolValue"|"doubleValue" => x}
  # A bare scalar passes through unchanged. arrayValue/kvlistValue keep their
  # structure (we don't flatten nested collections).
  module AttributeValue
    OTLP_SCALAR_KEYS = %w[stringValue intValue boolValue doubleValue].freeze

    module_function

    def unwrap(value)
      return value unless value.is_a?(Hash)
      return value["value"] if value.key?("value")
      OTLP_SCALAR_KEYS.each { |k| return value[k] if value.key?(k) }
      value["arrayValue"] || value["kvlistValue"]
    end
  end
end
