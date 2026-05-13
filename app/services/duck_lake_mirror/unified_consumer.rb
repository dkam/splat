# frozen_string_literal: true

module DuckLakeMirror
  # Single consumer that watches all four DuckLake mirror tubes and dispatches
  # each reserved job to its target model based on the `table:` field in the
  # body. Replaces the per-tube EventConsumer / IssueConsumer / TransactionConsumer
  # / SpanConsumer quartet. Tuber's reserve_batch pulls across watched tubes in
  # one call (FIFO by default), so the server gives us the union of work — no
  # idle-tube spin, no per-tube thread overhead.
  class UnifiedConsumer < Ingest::TubeConsumer
    TABLE_TO_MODEL = {
      "events"       => ::DuckLake::Event,
      "issues"       => ::DuckLake::Issue,
      "transactions" => ::DuckLake::Transaction,
      "spans"        => ::DuckLake::Span,
    }.freeze

    WATCHED_TUBES = [
      Ingest::Tuber::DUCKLAKE_EVENTS_TUBE,
      Ingest::Tuber::DUCKLAKE_ISSUES_TUBE,
      Ingest::Tuber::DUCKLAKE_TRANSACTIONS_TUBE,
      Ingest::Tuber::DUCKLAKE_SPANS_TUBE,
    ].freeze

    DEFAULT_BATCH_SIZE = ENV.fetch("DUCKLAKE_MIRROR_BATCH_SIZE", 500).to_i

    # Small coalesce wait when reserve returns a partial batch. Under low
    # traffic (a single event every few seconds) reserve_batch(500) returns
    # 1, the loop processes immediately, and each row pays its own DuckLake
    # catalog commit. 250ms gives stragglers a chance to collect into the
    # same multi_insert without adding meaningful latency to a mirror path.
    COALESCE_WAIT_S = ENV.fetch("DUCKLAKE_MIRROR_COALESCE_WAIT", "0.25").to_f

    Grouped = Struct.new(:jobs, :rows)

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: WATCHED_TUBES.first, batch_size: batch_size)
      # `watch!` REPLACES the watch list (beaneater/tube/collection.rb:210-214).
      # `super` already called `watch!(WATCHED_TUBES.first)`, which removed the
      # default-tube subscription. Use plain `watch` to add the remaining
      # tubes additively.
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

      grouped.each do |model, g|
        ok = g.rows.empty? || safe_multi_insert(model, g.rows)
        g.jobs.each { |job| safe_finalize(job, ok ? :ok : :retry) }
      end

      parse_failures.each { |job| safe_finalize(job, :retry) }
    end

    # Returns [Hash{model => Grouped}, Array<failed_jobs>]. Bodies are
    # expected to carry { table: "events"|..., rows: [...] }. If `table:`
    # is missing (legacy jobs queued before the producer change), fall
    # back to the last dot-segment of the tube name via Beaneater::Job#tube
    # — one STATS-JOB round-trip per legacy job, only during the migration
    # window.
    def group_by_target(jobs)
      grouped = Hash.new { |h, k| h[k] = Grouped.new([], []) }
      failures = []

      jobs.each do |job|
        body  = JSON.parse(job.body, symbolize_names: true)
        table = body[:table]&.to_s || tube_to_table(job)
        model = TABLE_TO_MODEL[table]

        if model.nil?
          log_exception("[#{self.class.name}] unknown table #{table.inspect}",
                        RuntimeError.new("no model for table"))
          failures << job
          next
        end

        g = grouped[model]
        g.jobs << job
        Array(body[:rows]).each { |r| g.rows << r }
      rescue => e
        log_exception("[#{self.class.name}] parse failed", e)
        failures << job
      end

      [grouped, failures]
    end

    # Last dot-segment of the tube name, e.g. "ducklake.spans" -> "spans".
    # Beaneater::Job#tube lazy-loads via STATS-JOB and caches on the object.
    def tube_to_table(job)
      job.tube.split(".").last
    end

    def safe_multi_insert(model, rows)
      model.multi_insert(rows)
      true
    rescue => e
      log_exception("[#{self.class.name}] multi_insert(#{model}) failed", e)
      false
    end
  end
end
