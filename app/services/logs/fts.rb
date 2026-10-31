# frozen_string_literal: true

module Logs
  # Writes to logs_fts, the search index in each day file (see
  # DayFiles::SCHEMA).
  #
  # The index is contentless (content=''): FTS5 stores the tokens and nothing
  # it could re-read them from, so there are no triggers to keep it in step and
  # no 'rebuild'. Whoever inserts a log row indexes it, in the same
  # transaction: Logs::Writer for ingest, Log's create callback for anything
  # else. Rows in a day file are never updated or deleted, so insert is the
  # only operation there is.
  #
  # Before ADR 0005 the index was external-content over logs.body and
  # logs.attrs_text, kept in sync by three triggers. The legacy database still
  # has that shape, and Log.search_text's MATCH reads either the same way.
  module Fts
    # Rows per INSERT statement: one statement for a typical batch, small
    # enough that a large OTLP request doesn't build one enormous SQL string.
    SLICE = 500

    module_function

    # entries: [[rowid, body, attrs_text], ...]
    def index(conn, entries)
      entries.each_slice(SLICE) do |slice|
        values = slice.map { |id, body, attrs| "(#{Integer(id)}, #{conn.quote(body)}, #{conn.quote(attrs)})" }
        conn.execute("INSERT INTO logs_fts (rowid, body, attrs_text) VALUES #{values.join(", ")}")
      end
    end
  end
end
