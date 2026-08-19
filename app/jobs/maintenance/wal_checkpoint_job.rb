# frozen_string_literal: true

module Maintenance
  # Explicit WAL checkpoints for the write-heavy databases.
  #
  # SQLite's automatic checkpoint is *passive*: at COMMIT, once the WAL passes
  # wal_autocheckpoint (1000 pages / 4 MB by default — we don't override it), it
  # copies frames into the main DB only until it meets an active reader, then
  # gives up and lets the WAL keep growing. That's fine when writes are cheap and
  # scattered readers are brief.
  #
  # It is not fine on the logs DB. Every Log.insert_all! also fires the three
  # logs_fts_* triggers, so a single batch scatters writes across a 15 GB FTS
  # index and 20 GB of secondary indexes inside a 110 GB file. Once the WAL got
  # ahead of the checkpointer it never recovered: each attempt had more frames to
  # copy, so it took longer, so it fell further behind — a runaway with no
  # equilibrium.
  #
  # Observed in production on 2026-08-17: production_logs.sqlite3-wal reached
  # 4.2 GB while every other WAL sat at its healthy 4 MB. LogConsumer was eating
  # 5s busy_timeouts on its own inserts, and the resulting disk churn pushed
  # unrelated databases (cable, issues_events, primary) into the same 5s wall —
  # a queue backlog that looked like a dead consumer but was a starved
  # checkpointer.
  #
  # TRUNCATE rather than PASSIVE is the entire point. PASSIVE is what already
  # runs automatically and what already lost the race; TRUNCATE waits for readers
  # (bounded by busy_timeout), copies every frame, and resets the WAL to zero, so
  # the backlog cannot accumulate across runs.
  #
  # A busy result is a normal outcome, not a failure: it means a reader held on
  # and the WAL is unchanged. The next run picks it up. We log it and move on
  # rather than raising, because one contended DB must not stop the others from
  # being checkpointed. A genuine per-DB error is isolated the same way so the
  # rest still run, but is re-raised once all DBs have been attempted, so it
  # doesn't look like an ordinary busy skip with nothing to alert on.
  class WalCheckpointJob
    # SQLite errors that mean "someone else has the file right now" rather than
    # "something is actually broken" — the same non-failure as busy=1. Threaded
    # checkpoints only ever target distinct DB files, so these can only come
    # from contention with a real writer elsewhere (e.g. LogConsumer), not from
    # this job's own threads colliding with each other.
    CONTENDED_ERRORS = [SQLite3::BusyException, SQLite3::LockedException].freeze

    # All 6 SQLite connections (config/database.yml) — including cache and
    # cable, both named as casualties of the 2026-08-17 incident this job
    # exists to prevent. Checkpointed concurrently below, so this ordering is
    # cosmetic, not a priority queue.
    DATABASES = {
      "logs" => "LogsRecord",
      "transactions_spans" => "TransactionsSpansRecord",
      "issues_events" => "IssuesEventsRecord",
      "primary" => "ApplicationRecord",
      "cache" => "SolidCache::Record",
      "cable" => "SolidCable::Record"
    }.freeze

    def perform(*names)
      targets = names.flatten.map(&:to_s).presence || DATABASES.keys

      # Concurrent, not sequential: this job shares splat.checkins with
      # Monitors::EvaluateJob, whose CheckInConsumer processes a batch on one
      # thread — a sequential loop's worst case stacks additively (~4-6x
      # busy_timeout) and can delay the dead-man's-switch sweep behind it,
      # defeating the reason this job is on that tube at all. Checkpointing
      # concurrently bounds the worst case to a single busy_timeout instead.
      threads = targets.filter_map do |name|
        klass = DATABASES[name]
        unless klass
          Rails.logger.warn "[#{self.class.name}] unknown database #{name.inspect}, skipping"
          next
        end
        Thread.new { [name, checkpoint(name, klass.constantize)] }
      end

      results = threads.to_h { |t| t.value }

      # checkpoint() isolates a per-DB failure so the others still run, but a
      # real failure (as opposed to routine busy=1 contention) must not come
      # back looking like an ordinary :ok run with nothing to alert on.
      failed = results.select { |_, r| r.is_a?(Hash) && r.key?(:error) }
      if failed.any?
        raise "[#{self.class.name}] failed for #{failed.keys.join(", ")}: " \
              "#{failed.map { |name, r| "#{name}: #{r[:error]}" }.join("; ")}"
      end

      results
    end

    private

    def checkpoint(name, model)
      conn = model.connection
      return nil unless conn.adapter_name.to_s.downcase.include?("sqlite")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Returns one row: busy | log (frames in WAL) | checkpointed (frames copied).
      # busy=1 means a reader blocked us and nothing was reset.
      row = conn.select_rows("PRAGMA wal_checkpoint(TRUNCATE)").first
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      busy, frames, checkpointed = Array(row).map(&:to_i)
      result = {busy: busy, frames: frames, checkpointed: checkpointed, ms: ms}

      if busy == 1
        Rails.logger.warn(
          "[#{self.class.name}] #{name}: busy after #{ms}ms — a reader held the " \
          "checkpoint off, WAL not reset (frames=#{frames})"
        )
      else
        Rails.logger.info(
          "[#{self.class.name}] #{name}: checkpointed #{checkpointed} frames in #{ms}ms"
        )
      end

      result
    rescue => e
      if CONTENDED_ERRORS.any? { |klass| e.cause.is_a?(klass) }
        Rails.logger.warn "[#{self.class.name}] #{name}: contended (#{e.cause.class}), unchanged — next run picks it up"
        {busy: 1, frames: 0, checkpointed: 0, ms: 0}
      else
        # One unreachable/broken DB must not stop the rest from being checkpointed.
        Rails.logger.error "[#{self.class.name}] #{name} failed: #{e.class}: #{e.message}"
        {error: "#{e.class}: #{e.message}"}
      end
    end
  end
end
