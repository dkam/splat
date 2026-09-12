module Maintenance
  # Daily delete-by-timestamp of aged events/transactions/spans across both
  # new SQLite files. Histograms are retained much longer than raw rows.
  # After each table's batch loop we run PRAGMA incremental_vacuum on the
  # affected DB to actually return pages to disk (auto_vacuum is set to
  # INCREMENTAL on these DBs, so freed pages don't get reclaimed until we ask).
  class RetentionJob
    BATCH_SIZE = 500
    SLEEP_BETWEEN_BATCHES = 0.05
    # Argument to `PRAGMA incremental_vacuum(N)`.
    #
    # Measured (auto_vacuum=INCREMENTAL, WAL, 4 KB pages): each call reclaims
    # exactly ONE page whatever N is — (1), (10) and (50) all reclaim one, most
    # likely because the driver steps the pragma's statement once rather than to
    # completion. So N is close to inert and the number of *calls* is what
    # reclaims space. That is why the old single-call version returned 4 KB per
    # database per day against deletes freeing several GB, and why the loop
    # below is keyed off freelist_count rather than off this number.
    VACUUM_PAGES = 1000
    # Per-database budget. The freelist survives across runs, so stopping early
    # costs nothing but time — the next run resumes where this one stopped.
    VACUUM_MAX_SECONDS = 120
    # Breathe periodically so ingest and the hourly rollup can get the lock.
    # Every step would be far too often: a step costs ~0.1ms and reclaims one
    # page, so sleeping 50ms after each would cap a 120s budget at ~2400 pages
    # (~10 MB) and the backlog would never clear. Batching the pause keeps a
    # roughly 1:2 work:sleep duty cycle while reclaiming on the order of a GB
    # per run. (Each PRAGMA is its own implicit transaction, so the write lock
    # is already released between steps; this just widens the window.)
    VACUUM_STEP_PAUSE = 0.05
    VACUUM_PAUSE_EVERY = 200
    # StatementTimeout/LockWaitTimeout are both StatementInvalid subclasses, so
    # contention is identified by message rather than class.
    BUSY_MESSAGE = /database (?:table )?is locked|BusyException/i

    def perform
      Rails.logger.info "[Maintenance::RetentionJob] starting"
      start = Time.current
      setting = Setting.instance

      events_deleted = retire_events(setting.events_data_cutoff_date)
      transactions_deleted, spans_deleted, span_trees_deleted = retire_transactions_and_spans(
        transactions_cutoff: setting.transactions_data_cutoff_date,
        spans_cutoff: setting.spans_data_cutoff_date
      )
      logs_deleted = retire_logs(setting.logs_data_cutoff_date)
      # Both aggregate tables share the long histogram retention clock — they're
      # the historical performance record that outlives the raw transactions.
      histograms_deleted = retire_histograms(setting.histograms_cutoff_date)
      hourly_stats_deleted = retire_hourly_stats(setting.histograms_cutoff_date)
      facets_deleted = retire_facets(setting)
      # Lives on issues_events, so it must be deleted before that DB is vacuumed.
      issue_facets_deleted = retire_issue_facets(setting.events_data_cutoff_date)

      vacuum(IssuesEventsRecord)
      vacuum(TransactionsSpansRecord)
      vacuum(LogsRecord)

      duration = (Time.current - start).round(2)
      Rails.logger.info "[Maintenance::RetentionJob] done in #{duration}s — events:#{events_deleted}, transactions:#{transactions_deleted}, spans:#{spans_deleted}, span_trees:#{span_trees_deleted}, logs:#{logs_deleted}, histograms:#{histograms_deleted}, hourly_stats:#{hourly_stats_deleted}, facets:#{facets_deleted}, issue_facets:#{issue_facets_deleted}"
      {
        duration: duration,
        events_deleted: events_deleted,
        transactions_deleted: transactions_deleted,
        spans_deleted: spans_deleted,
        span_trees_deleted: span_trees_deleted,
        logs_deleted: logs_deleted,
        histograms_deleted: histograms_deleted,
        hourly_stats_deleted: hourly_stats_deleted,
        facets_deleted: facets_deleted,
        issue_facets_deleted: issue_facets_deleted
      }
    end

    private

    # Drop facet values not seen within their stream's data-retention window: a
    # value absent that long points at zero surviving rows, so it should leave the
    # dropdown. facets is on the primary DB (not vacuumed here); the churn is a
    # handful of rows, so incremental_vacuum isn't worth it.
    def retire_facets(setting)
      batched_delete_all(Facet.where(stream: "log").where("last_seen_at < ?", setting.logs_data_cutoff_date)) +
        batched_delete_all(Facet.where(stream: "transaction").where("last_seen_at < ?", setting.transactions_data_cutoff_date))
    end

    # Same rule as retire_facets, on the events clock: once every event carrying
    # the value has aged out, the issue can no longer be said to have been seen
    # there, so it should stop matching that filter. Separate from retire_facets
    # because this table is on issues_events and scales with issues × values,
    # rather than being the primary DB's small closed set of dropdown options.
    def retire_issue_facets(cutoff)
      batched_delete_all(IssueFacet.where("last_seen_at < ?", cutoff))
    end

    def retire_logs(cutoff)
      batched_delete_all(Log.where("timestamp < ?", cutoff))
    end

    def retire_events(cutoff)
      scope = Event.where("timestamp < ?", cutoff)
      affected_issue_ids = scope.distinct.pluck(:issue_id).compact
      deleted = batched_delete_all(scope)
      recount_issues(affected_issue_ids)
      deleted
    end

    # Delete aged transactions, the span-tree blobs tied to them, and (during the
    # dual-read window) any legacy per-span rows. Spans/span_trees share the
    # shorter span retention window, so we drop those first by their own cutoff.
    #
    # The legacy `Span` pruning stays until the blob cutover's transactions have
    # fully aged out (~30 days); after that, drop the Span branches here, the
    # `spans` table, and the from_record fallback in Span.for_transaction.
    def retire_transactions_and_spans(transactions_cutoff:, spans_cutoff:)
      spans_deleted = batched_delete_all(Span.where("timestamp < ?", spans_cutoff))
      span_trees_deleted = batched_delete_all(SpanTree.where("timestamp < ?", spans_cutoff))

      txn_scope = Transaction.where("timestamp < ?", transactions_cutoff)
      # Drop any remaining spans/span_trees linked to retiring transactions,
      # regardless of span cutoff. Stream (project_id, transaction_id) pairs in
      # batches — avoids materialising every retiring UUID at once, and keeps the
      # delete scoped to the project (transaction_id is not globally unique).
      txn_scope.in_batches(of: BATCH_SIZE) do |batch|
        batch.pluck(:project_id, :transaction_id).group_by(&:first).each do |project_id, pairs|
          ids = pairs.map(&:last)
          spans_deleted += Span.where(project_id: project_id, transaction_id: ids).delete_all
          span_trees_deleted += SpanTree.where(project_id: project_id, transaction_id: ids).delete_all
        end
        sleep SLEEP_BETWEEN_BATCHES
      end
      txn_deleted = batched_delete_all(txn_scope)
      [txn_deleted, spans_deleted, span_trees_deleted]
    end

    def retire_histograms(cutoff)
      batched_delete_all(TransactionHistogramAR.where("hour_bucket < ?", cutoff))
    end

    def retire_hourly_stats(cutoff)
      batched_delete_all(TransactionHourlyStatAR.where("hour_bucket < ?", cutoff))
    end

    # Step incremental_vacuum until the freelist is drained, the budget runs
    # out, or another writer wants the lock.
    #
    # This used to be a single `incremental_vacuum(1000)` call per database per
    # run — 4 MB against daily deletes that free several GB, so the freelist
    # only ever grew and the files never shrank. (That is what the Booko notes
    # saw as a retention problem; retention was fine.) Looping is the fix, but
    # it has to stay polite: Analytics::HistogramRollupJob fires hourly against
    # this same DB and gets buried if it can't get in, so yield on the first
    # sign of contention rather than grinding.
    def vacuum(base, pages: VACUUM_PAGES, max_seconds: VACUUM_MAX_SECONDS, pause: VACUUM_STEP_PAUSE)
      conn = base.connection

      # Checkpoint first, or there is close to nothing to reclaim. A free page
      # the WAL still references can't be truncated out of the main DB file, and
      # the deletes above have just written a large WAL — so vacuuming straight
      # after them reclaims almost nothing and gives up on the no-progress
      # break below. PASSIVE won't fight readers: it does what it can and
      # returns, leaving the rest to Maintenance::WalCheckpointJob.
      begin
        conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
      rescue ActiveRecord::StatementInvalid => e
        # Not fatal — just means less is reclaimable this pass.
        Rails.logger.warn "[Maintenance::RetentionJob] checkpoint before vacuum failed on #{base}: #{e.message}"
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + max_seconds
      before = freelist_count(conn)
      steps = 0

      remaining = before
      while remaining > 0
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        conn.execute("PRAGMA incremental_vacuum(#{pages})")
        steps += 1

        # Stop as soon as a step reclaims nothing. In WAL mode not every free
        # page is reclaimable right now — pages the WAL still references can't
        # be truncated until it checkpoints — and without this the loop spins
        # at full tilt against the freelist until the budget expires, holding
        # the connection for two minutes and reclaiming zero. Whatever is left
        # is still on the freelist for the next run.
        progressed = freelist_count(conn)
        break if progressed >= remaining

        remaining = progressed
        sleep pause if pause > 0 && (steps % VACUUM_PAUSE_EVERY).zero?
      end

      after = freelist_count(conn)
      # Say which stopping rule fired — "still 5M pages free" reads very
      # differently depending on whether we ran out of time or SQLite simply
      # wouldn't give the pages back yet.
      stopped =
        if after.zero? then "drained"
        elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline then "hit #{max_seconds}s budget"
        else "no further pages reclaimable (WAL still references them)"
        end
      Rails.logger.info(
        "[Maintenance::RetentionJob] vacuum #{base}: freelist #{before} -> #{after} " \
        "in #{steps} step(s) — #{stopped}#{", resuming next run" unless after.zero?}"
      )
      {freelist_before: before, freelist_after: after, steps: steps}
    rescue ActiveRecord::StatementInvalid => e
      # Contention is expected and fine — the freelist persists, so whatever is
      # left just gets picked up next run. Anything else (no such pragma, a
      # non-SQLite adapter) is equally not worth aborting the whole retention
      # pass for, but say which happened.
      reason = e.message.match?(BUSY_MESSAGE) ? "database locked" : e.message
      Rails.logger.warn "[Maintenance::RetentionJob] incremental_vacuum stopped on #{base}: #{reason}"
      nil
    end

    def freelist_count(conn)
      conn.select_value("PRAGMA freelist_count").to_i
    end

    def batched_delete_all(scope)
      total = 0
      scope.in_batches(of: BATCH_SIZE) do |batch|
        total += batch.delete_all
        sleep SLEEP_BETWEEN_BATCHES
      end
      total
    end

    def recount_issues(issue_ids)
      return if issue_ids.empty?
      issue_ids.each_slice(BATCH_SIZE) do |batch|
        Issue.where(id: batch).update_all(
          "count = (SELECT COUNT(*) FROM events WHERE events.issue_id = issues.id)"
        )
        sleep SLEEP_BETWEEN_BATCHES
      end
    end

    # The aggregate tables have no Ruby model — define thin ones inline so
    # we can use scope chaining + in_batches.
    class TransactionHistogramAR < TransactionsSpansRecord
      self.table_name = "transaction_histograms"
    end

    class TransactionHourlyStatAR < TransactionsSpansRecord
      self.table_name = "transaction_hourly_stats"
    end
  end
end
