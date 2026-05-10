# frozen_string_literal: true

module DuckLakeMirror
  # Stage 2: drains one DuckLake mirror tube and collapses the whole batch
  # into a single multi_insert. Subclasses set tube + target_model and
  # optionally override #extract_rows for tubes whose bodies carry arrays.
  class BaseConsumer < ::Ingest::TubeConsumer
    DEFAULT_BATCH_SIZE = 500

    def initialize(tube:, target_model:, batch_size: DEFAULT_BATCH_SIZE)
      @target_model = target_model
      super(tube: tube, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      rows = []
      parse_failures = []
      ok_jobs = []

      jobs.each do |job|
        rows.concat(extract_rows(job.body))
        ok_jobs << job
      rescue => e
        Rails.logger.error "[#{self.class.name}] parse failed: #{e.class}: #{e.message}"
        parse_failures << job
      end

      insert_ok = rows.empty? || multi_insert_rows(rows)

      ok_jobs.each { |job| safe_finalize(job, insert_ok ? :ok : :retry) }
      parse_failures.each { |job| safe_finalize(job, :retry) }
    end

    def multi_insert_rows(rows)
      @target_model.multi_insert(rows)
      true
    rescue => e
      Rails.logger.error "[#{self.class.name}] multi_insert failed: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      false
    end

    # Default: one row per body. Override for tubes whose body carries an
    # array (spans).
    def extract_rows(body)
      [JSON.parse(body, symbolize_names: true)]
    end
  end
end
