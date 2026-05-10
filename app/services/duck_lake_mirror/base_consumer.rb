# frozen_string_literal: true

module DuckLakeMirror
  # Stage 2: drains one DuckLake mirror tube and collapses the whole batch
  # into a single multi_insert. Bodies always carry { rows: [...] } so stage 1
  # can pack a whole batch into a single tube put.
  class BaseConsumer < ::Ingest::TubeConsumer
    # Reserved bodies stay in RAM until the multi_insert finishes. With
    # packed bodies (spans especially can be multi-MB each), 500 reserved
    # bodies × multi-MB each is significant — but works fine in a ~4GB
    # container. Reduce via ENV["DUCKLAKE_MIRROR_BATCH_SIZE"] if memory-
    # constrained.
    DEFAULT_BATCH_SIZE = ENV.fetch("DUCKLAKE_MIRROR_BATCH_SIZE", 500).to_i

    # When a reserve returns fewer than @batch_size jobs (low traffic),
    # wait this long and reserve again to coalesce more rows into a single
    # multi_insert. Without this, low-traffic deploys hit the catalog
    # ~1 commit/row — defeating the whole point of stage-2 batching.
    COALESCE_WAIT_S = ENV.fetch("DUCKLAKE_MIRROR_COALESCE_WAIT", "1.0").to_f

    def initialize(tube:, target_model:, batch_size: DEFAULT_BATCH_SIZE)
      @target_model = target_model
      super(tube: tube, batch_size: batch_size)
    end

    private

    # Override TubeConsumer#reserve_batch with a two-phase reserve. Phase 1
    # is the normal non-blocking grab. If it returned the full batch, ship
    # immediately. Otherwise sleep briefly so more bodies accumulate, then
    # top up. Stage 1 producers will deposit during the sleep.
    def reserve_batch
      jobs = @client.tubes.reserve_batch(@batch_size)
      return jobs if jobs.empty? || jobs.size >= @batch_size || COALESCE_WAIT_S <= 0

      sleep COALESCE_WAIT_S
      begin
        extra = @client.tubes.reserve_batch(@batch_size - jobs.size)
        jobs.concat(extra)
      rescue Beaneater::TimedOutError
        # Nothing arrived during the wait — ship what we have.
      end
      jobs
    rescue Beaneater::TimedOutError
      []
    end

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
