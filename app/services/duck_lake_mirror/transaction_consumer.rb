# frozen_string_literal: true

module DuckLakeMirror
  class TransactionConsumer < BaseConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: ::Ingest::Tuber::DUCKLAKE_TRANSACTIONS_TUBE,
            target_model: ::DuckLake::Transaction,
            batch_size: batch_size)
    end
  end
end
