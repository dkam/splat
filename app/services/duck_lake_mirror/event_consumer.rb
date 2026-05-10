# frozen_string_literal: true

module DuckLakeMirror
  class EventConsumer < BaseConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: ::Ingest::Tuber::DUCKLAKE_EVENTS_TUBE,
            target_model: ::DuckLake::Event,
            batch_size: batch_size)
    end
  end
end
