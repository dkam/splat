# frozen_string_literal: true

module DuckLakeMirror
  # Spans tube bodies carry { rows: [span_row, span_row, ...] } — one body
  # per source transaction. Flattening across many bodies into one
  # multi_insert is the whole point of stage 2 here.
  class SpanConsumer < BaseConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: ::Ingest::Tuber::DUCKLAKE_SPANS_TUBE,
            target_model: ::DuckLake::Span,
            batch_size: batch_size)
    end

    private

    def extract_rows(body)
      parsed = JSON.parse(body, symbolize_names: true)
      Array(parsed[:rows])
    end
  end
end
