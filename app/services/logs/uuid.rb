# frozen_string_literal: true

module Logs
  # Collapses canonical hyphenated UUIDs to a single hyphen-free token, used on
  # both sides of full-text search so they stay in sync:
  #   * index side  (Logs::AttrsText) — store "…550e8400e29b41d4a716446655440000…"
  #   * query side  (Log.fts_query)   — normalize the user's pasted UUID the same way
  #
  # Why: the FTS5 unicode61 tokenizer splits on "-", so a UUID would otherwise
  # become five near-unique tokens — bloating the index and letting a fragment
  # ("e29b") loosely match unrelated rows. One token is smaller and matches the
  # whole id exactly. ULIDs are already hyphen-free, so they need no handling.
  module Uuid
    # 8-4-4-4-12 hex, with word boundaries so an embedded UUID (e.g. in a path)
    # is caught but "1.4.0-dev" / "trace-id-foo" are not.
    CANONICAL = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i

    module_function

    def collapse(text)
      return text if text.nil?
      text.to_s.gsub(CANONICAL) { |m| m.delete("-") }
    end
  end
end
