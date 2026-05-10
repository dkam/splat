# frozen_string_literal: true

module DuckLakeMirror
  # Stage 2: drains one DuckLake mirror tube and collapses the whole batch
  # into a single multi_insert. Bodies always carry { rows: [...] } so stage 1
  # can pack a whole batch into a single tube put.
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
        log_exception("[#{self.class.name}] parse failed", e)
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
      log_exception("[#{self.class.name}] multi_insert failed", e)
      false
    end

    def extract_rows(body)
      Array(JSON.parse(body, symbolize_names: true)[:rows])
    end
  end
end
