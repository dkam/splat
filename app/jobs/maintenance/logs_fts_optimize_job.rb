# frozen_string_literal: true

module Maintenance
  # Incremental segment merge for the logs_fts FTS5 search index. RetentionJob's
  # log deletes only write delete-markers into the index — FTS5 never merges old
  # segments on its own beyond its automerge budget, so dead entries accumulate
  # without bound. The follow-up incremental_vacuum (the logs DB runs
  # auto_vacuum=INCREMENTAL) hands freed pages back to the OS.
  #
  # Why stepped 'merge' and not 'optimize':
  #
  # 'optimize' is defined by SQLite as `merge -N` followed by repeated `merge N`
  # until no work remains — it collapses every b-tree into one, in a single
  # unbounded operation. That was fine at the size this job was written for
  # (429 MB of logs_fts_data). At 15.3 GB it rewrites the whole index inside one
  # write transaction: the logs DB write lock is held for the duration, and every
  # rewritten page lands in a WAL that cannot checkpoint until it commits. On a
  # 110 GB file that is hours of held lock and gigabytes of WAL.
  #
  # Positive-N 'merge' does at most ~N pages of work per statement, and each
  # statement is its own implicit transaction. The lock is released between
  # steps, the WAL stays checkpointable, and ingest interleaves normally. We
  # deliberately do NOT use the negative-N form: it assigns every b-tree to one
  # level and restarts if new b-trees appear mid-merge, which on a continuously
  # written index means it may never converge. The goal here is a tidy index, not
  # a single segment.
  #
  # Termination follows the documented contract: a merge step that changes fewer
  # than 2 rows did no work, so there is nothing left to merge.
  class LogsFtsOptimizeJob
    # Pages of merge work per step. Each step is one transaction, so this also
    # bounds how much WAL a single step can produce.
    MERGE_PAGES = 500

    # Wall-clock budget for the whole run. The index does not have to be fully
    # merged in one night — falling behind by a little is fine, holding the write
    # lock for hours is not. Whatever is left is picked up by the next run.
    MAX_SECONDS = 20 * 60

    # Freelist pages reclaimed per incremental_vacuum step. Uncapped
    # `PRAGMA incremental_vacuum` has the same unbounded-transaction problem as
    # 'optimize' — on the logs DB that is ~2M free pages (8 GB) in one shot.
    VACUUM_PAGES = 2_000

    def perform(max_seconds: MAX_SECONDS)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + max_seconds.to_i
      conn = LogsRecord.connection

      pages_before = conn.select_value("PRAGMA page_count").to_i
      merge_steps = merge!(conn, deadline)
      vacuumed = vacuum!(conn, deadline)
      pages_after = conn.select_value("PRAGMA page_count").to_i

      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      exhausted = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Rails.logger.info(
        "[#{self.class.name}] done in #{duration}s — merge_steps:#{merge_steps}, " \
        "pages_reclaimed:#{vacuumed}, pages #{pages_before} -> #{pages_after}" \
        "#{" (hit #{max_seconds}s budget, resuming next run)" if exhausted}"
      )

      {duration: duration, pages_before: pages_before, pages_after: pages_after,
       merge_steps: merge_steps, pages_reclaimed: vacuumed, budget_exhausted: exhausted}
    rescue ActiveRecord::StatementInvalid => e
      # logs_fts may not exist (fresh DB before Logs::Fts.ensure! ran, or a
      # non-SQLite adapter) — skip rather than crash the maintenance worker.
      Rails.logger.warn "[#{self.class.name}] skipped: #{e.message}"
      nil
    end

    private

    # Step the merge until it reports no work left or we run out of budget.
    # total_changes() is SQLite's cumulative row-change counter; a step that
    # moves it by less than 2 merged nothing (documented FTS5 contract).
    def merge!(conn, deadline)
      steps = 0

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        before = conn.select_value("SELECT total_changes()").to_i
        conn.execute("INSERT INTO logs_fts(logs_fts, rank) VALUES('merge', #{MERGE_PAGES})")
        after = conn.select_value("SELECT total_changes()").to_i

        steps += 1
        break if (after - before) < 2
      end

      steps
    end

    # Hand freed pages back to the OS in bounded chunks, stopping when the
    # freelist is empty, a step makes no progress, or the budget runs out.
    def vacuum!(conn, deadline)
      reclaimed = 0

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        before = conn.select_value("PRAGMA freelist_count").to_i
        break if before.zero?

        conn.execute("PRAGMA incremental_vacuum(#{VACUUM_PAGES})")
        after = conn.select_value("PRAGMA freelist_count").to_i

        break if after >= before
        reclaimed += (before - after)
      end

      reclaimed
    end
  end
end
