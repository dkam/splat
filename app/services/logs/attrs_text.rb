# frozen_string_literal: true

module Logs
  # Flattens a record's attributes into a space-joined "key value key value"
  # string for the logs_fts free-text index. Source-agnostic: callers pass a
  # plain {key => value} map (Sentry values may be {"value" => x} objects;
  # OTLP values arrive already unwrapped).
  module AttrsText
    # Floating-point values (durations, runtimes like "317.42") are unique per
    # row and pure FTS noise — each distinct timing becomes its own index term,
    # bloating the dictionary for something nobody full-text-searches. Skip the
    # value (the key is still emitted, and the exact number stays in the
    # compressed payload for the detail view). Integers like a "422" status are
    # low-cardinality and worth keeping.
    FLOAT_VALUE = /\A-?\d+\.\d+\z/

    module_function

    def build(pairs)
      return nil if pairs.blank?

      out = []
      pairs.each do |key, value|
        next if key.blank?
        out << key.to_s
        scalar = unwrap(value)
        str = scalar.to_s
        # Collapse hyphenated UUIDs to one token so they index as a single,
        # exact-matchable term instead of five hyphen-split fragments.
        out << Logs::Uuid.collapse(str) unless scalar.nil? || str.empty? || str.match?(FLOAT_VALUE)
      end
      out.join(" ").presence
    end

    def unwrap(value) = Logs::AttributeValue.unwrap(value)
  end
end
