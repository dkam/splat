module Maintenance
  # Daily delete-by-timestamp of aged events/transactions/spans across both
  # new SQLite files. Histograms are retained much longer than raw rows.
  # After each table's batch loop we run PRAGMA incremental_vacuum on the
  # affected DB to actually return pages to disk (auto_vacuum is set to
  # INCREMENTAL on these DBs, so freed pages don't get reclaimed until we ask).
  class RetentionJob
    BATCH_SIZE = 500
    SLEEP_BETWEEN_BATCHES = 0.05
    VACUUM_PAGES = 1000

    def perform
      Rails.logger.info "[Maintenance::RetentionJob] starting"
      start = Time.current
      setting = Setting.instance

      events_deleted = retire_events(setting.events_data_cutoff_date)
      transactions_deleted, spans_deleted = retire_transactions_and_spans(
        transactions_cutoff: setting.transactions_data_cutoff_date,
        spans_cutoff:        setting.spans_data_cutoff_date
      )
      histograms_deleted = retire_histograms(setting.histograms_cutoff_date)

      vacuum(IssuesEventsRecord)
      vacuum(TransactionsSpansRecord)

      duration = (Time.current - start).round(2)
      Rails.logger.info "[Maintenance::RetentionJob] done in #{duration}s — events:#{events_deleted}, transactions:#{transactions_deleted}, spans:#{spans_deleted}, histograms:#{histograms_deleted}"
      {
        duration:           duration,
        events_deleted:     events_deleted,
        transactions_deleted: transactions_deleted,
        spans_deleted:      spans_deleted,
        histograms_deleted: histograms_deleted
      }
    end

    private

    def retire_events(cutoff)
      scope = Event.where("timestamp < ?", cutoff)
      affected_issue_ids = scope.distinct.pluck(:issue_id).compact
      deleted = batched_delete_all(scope)
      recount_issues(affected_issue_ids)
      deleted
    end

    # Delete aged transactions (and the spans tied to them by transaction_id)
    # plus any orphan-aged spans. Spans are typically retained for a shorter
    # window than transactions, so we drop those first by their own cutoff.
    def retire_transactions_and_spans(transactions_cutoff:, spans_cutoff:)
      spans_deleted = batched_delete_all(Span.where("timestamp < ?", spans_cutoff))

      txn_scope = Transaction.where("timestamp < ?", transactions_cutoff)
      # Drop any remaining spans linked to retiring transactions, regardless of span cutoff.
      retiring_txn_ids = txn_scope.pluck(:transaction_id)
      retiring_txn_ids.each_slice(BATCH_SIZE) do |batch|
        spans_deleted += Span.where(transaction_id: batch).delete_all
        sleep SLEEP_BETWEEN_BATCHES
      end
      txn_deleted = batched_delete_all(txn_scope)
      [txn_deleted, spans_deleted]
    end

    def retire_histograms(cutoff)
      batched_delete_all(TransactionHistogramAR.where("hour_bucket < ?", cutoff))
    end

    def vacuum(base)
      base.connection.execute("PRAGMA incremental_vacuum(#{VACUUM_PAGES})")
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn "[Maintenance::RetentionJob] incremental_vacuum failed on #{base}: #{e.message}"
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

    # transaction_histograms has no Ruby model — define a thin one inline so
    # we can use scope chaining + in_batches.
    class TransactionHistogramAR < TransactionsSpansRecord
      self.table_name = "transaction_histograms"
    end
  end
end
