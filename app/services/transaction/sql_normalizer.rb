# frozen_string_literal: true

class Transaction::SqlNormalizer
  MAX_LEN = 4000

  STRING_LITERAL  = /'(?:[^'\\]|\\.|'')*'/
  NUMERIC_LITERAL = /(?<![A-Za-z_\d])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/
  IN_LIST         = /\bIN\s*\(\s*\?(?:\s*,\s*\?)+\s*\)/i
  WHITESPACE      = /\s+/

  # Normalize a span description (typically SQL or URL) for storage.
  #
  # Two goals:
  #   1. Compression — collapse near-duplicate strings to a small dictionary.
  #   2. Privacy — literal values (user IDs, emails in WHERE clauses, names
  #      in INSERTs) never reach disk. Only the parameterized form is stored.
  #
  # We may be called with non-SQL strings too (URLs, op descriptions); the
  # transformations are conservative and safe for those.
  def self.normalize(text)
    return nil if text.nil?
    s = text.to_s.dup

    # PostgreSQL-style double-quoted identifiers ("users") are NOT literals;
    # leave them. Only collapse single-quoted strings.
    s = s.gsub(STRING_LITERAL, "?")
    s = s.gsub(NUMERIC_LITERAL, "?")
    s = s.gsub(IN_LIST, "IN (?)")
    s = s.gsub(WHITESPACE, " ").strip

    s.byteslice(0, MAX_LEN)
  end
end
