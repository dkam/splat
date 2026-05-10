# frozen_string_literal: true

module DuckLakeMirror
  class IssueConsumer < BaseConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: ::Ingest::Tuber::DUCKLAKE_ISSUES_TUBE,
            target_model: ::DuckLake::Issue,
            batch_size: batch_size)
    end
  end
end
