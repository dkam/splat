# frozen_string_literal: true

module DuckLakeMirror
  # Single consumer that watches the analytics mirror tubes (events,
  # transactions, spans) and dispatches each reserved job to the
  # ParquetLake::Writer using the `table:` field in the body.
  #
  # Tuber's reserve_batch pulls across watched tubes in one call (FIFO by
  # default), so the server gives us the union of work — no idle-tube spin
  # or per-tube thread overhead. Coalescing into one Writer.write call per
  # (table, batch) keeps row groups dense for ZSTD/dictionary compression.
  class UnifiedConsumer < Ingest::TubeConsumer
    VALID_TABLES = %w[events transactions spans].to_set.freeze

    WATCHED_TUBES = [
      ::Ingest::Tuber::DUCKLAKE_EVENTS_TUBE,
      ::Ingest::Tuber::DUCKLAKE_TRANSACTIONS_TUBE,
      ::Ingest::Tuber::DUCKLAKE_SPANS_TUBE
    ].freeze

    DEFAULT_BATCH_SIZE = ENV.fetch("DUCKLAKE_MIRROR_BATCH_SIZE", 500).to_i

    # Small coalesce wait when reserve returns a partial batch. Under low
    # traffic (a single event every few seconds) reserve_batch(500) returns
    # 1, the loop processes immediately. 250ms gives stragglers a chance to
    # collect into the same Writer.write batch — fewer, denser Parquet files.
    COALESCE_WAIT_S = ENV.fetch("DUCKLAKE_MIRROR_COALESCE_WAIT", "0.25").to_f

    Grouped = Struct.new(:jobs, :rows)

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: WATCHED_TUBES.first, batch_size: batch_size)
      # TubeConsumer's `watch!(WATCHED_TUBES.first)` REPLACES the watch list
      # (beaneater/tube/collection.rb:210-214) and drops the default-tube
      # subscription. Use plain `watch` to add the remaining tubes additively.
      WATCHED_TUBES[1..].each { |t| @client.tubes.watch(t) }
    end

    private

    # Two-phase reserve: grab whatever's immediately ready, briefly wait, top up.
    def reserve_batch
      jobs = @client.tubes.reserve_batch(@batch_size)
      return jobs if jobs.empty? || jobs.size >= @batch_size || COALESCE_WAIT_S <= 0

      sleep COALESCE_WAIT_S
      begin
        extra = @client.tubes.reserve_batch(@batch_size - jobs.size)
        jobs.concat(extra)
      rescue Beaneater::TimedOutError
        # Nothing more arrived during the wait — ship what we have.
      end
      jobs
    rescue Beaneater::TimedOutError
      []
    end

    def process_batch(jobs)
      grouped, parse_failures = group_by_target(jobs)

      grouped.each do |table, g|
        ok = g.rows.empty? || safe_write(table, g.rows)
        g.jobs.each { |job| safe_finalize(job, ok ? :ok : :retry) }
      end

      parse_failures.each { |job| safe_finalize(job, :retry) }
    end

    # Returns [Hash{table_name => Grouped}, Array<failed_jobs>]. Bodies are
    # expected to carry { table: "events"|"transactions"|"spans", rows: [...] }.
    # If `table:` is missing (legacy jobs queued before the producer change),
    # fall back to the last dot-segment of the tube name via Beaneater::Job#tube
    # — one STATS-JOB round-trip per legacy job, only during the migration
    # window.
    def group_by_target(jobs)
      grouped = Hash.new { |h, k| h[k] = Grouped.new([], []) }
      failures = []

      jobs.each do |job|
        body  = JSON.parse(job.body, symbolize_names: true)
        table = body[:table]&.to_s || tube_to_table(job)

        unless VALID_TABLES.include?(table)
          log_exception("[#{self.class.name}] unknown table #{table.inspect}",
                        RuntimeError.new("not in VALID_TABLES"))
          failures << job
          next
        end

        g = grouped[table]
        g.jobs << job
        Array(body[:rows]).each { |r| g.rows << r }
      rescue => e
        log_exception("[#{self.class.name}] parse failed", e)
        failures << job
      end

      [grouped, failures]
    end

    # Last dot-segment of the tube name, e.g. "splat.ducklake.spans" -> "spans".
    # Beaneater::Job#tube lazy-loads via STATS-JOB and caches on the object.
    def tube_to_table(job)
      job.tube.split(".").last
    end

    def safe_write(table, rows)
      ParquetLake::Writer.write(table: table, rows: rows)
      true
    rescue => e
      log_exception("[#{self.class.name}] Writer.write(#{table}) failed", e)
      false
    end
  end
end
