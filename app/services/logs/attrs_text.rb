# frozen_string_literal: true

module Logs
  # Flattens a record's attributes into a space-joined "key value key value"
  # string for the logs_fts free-text index. Source-agnostic: callers pass a
  # plain {key => value} map (Sentry values may be {"value" => x} objects;
  # OTLP values arrive already unwrapped).
  module AttrsText
    module_function

    def build(pairs)
      return nil if pairs.blank?

      out = []
      pairs.each do |key, value|
        next if key.blank?
        out << key.to_s
        scalar = unwrap(value)
        out << scalar.to_s unless scalar.nil? || scalar.to_s.empty?
      end
      out.join(" ").presence
    end

    def unwrap(value) = Logs::AttributeValue.unwrap(value)
  end
end
