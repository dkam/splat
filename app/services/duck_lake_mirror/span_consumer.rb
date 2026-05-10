# frozen_string_literal: true

module DuckLakeMirror
  class SpanConsumer < BaseConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: ::Ingest::Tuber::DUCKLAKE_SPANS_TUBE,
            target_model: ::DuckLake::Span,
            batch_size: batch_size)
    end
  end
end
