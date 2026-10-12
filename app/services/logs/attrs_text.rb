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

    # Longest value (in characters) that reaches the index. Database-query logs
    # carry their whole SQL statement as an attribute — a bulk upsert's VALUES
    # list runs to hundreds of KB of near-unique numbers, and in production
    # three such query types were 0.6% of logs but two-thirds of all indexed
    # attribute text. The head of a value is what anyone searches on; the full
    # value stays in the compressed payload for the detail view.
    MAX_VALUE_CHARS = 512

    # A run of token characters at the end of a truncated value — the tail of
    # a word the cut went through, which would index as a bogus term.
    TRAILING_TOKEN = /[\p{Alnum}_]+\z/

    module_function

    def build(pairs)
      return nil if pairs.blank?

      out = []
      pairs.each do |key, value|
        next if key.blank?
        out << key.to_s
        scalar = unwrap(value)
        str = scalar.to_s
        next if scalar.nil? || str.empty? || str.match?(FLOAT_VALUE)
        # Collapse hyphenated UUIDs to one token so they index as a single,
        # exact-matchable term instead of five hyphen-split fragments. Before
        # truncating, so the cut can't land inside a UUID and leave it
        # uncollapsible.
        out << truncate(Logs::Uuid.collapse(str))
      end
      out.join(" ").presence
    end

    def truncate(str)
      return str if str.length <= MAX_VALUE_CHARS

      head = str[0, MAX_VALUE_CHARS]
      # Cut went through a word: drop its fragment rather than index it.
      head = head.sub(TRAILING_TOKEN, "") if str[MAX_VALUE_CHARS].match?(/[\p{Alnum}_]/)
      head
    end

    def unwrap(value) = Logs::AttributeValue.unwrap(value)
  end
end
