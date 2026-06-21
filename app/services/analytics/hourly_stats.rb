module Analytics
  # Live-hour scalar aggregates for transactions, written to
  # transaction_hourly_stats at ingest (and overwritten authoritatively by the
  # hourly rollup). Companion to Analytics::Histogram: the histogram keeps the
  # duration *distribution* (percentiles), this keeps the scalars the dashboard
  # and MCP also report — count, sums for averages, max/min, query + N+1 + 5xx
  # counts. Both outlive the raw transactions (retained on the histogram clock),
  # so endpoint stats and volume/avg charts survive (and stay fast) after the
  # raw rows are deleted.
  #
  # Idempotent it is NOT (each call adds): only call once per inserted
  # transaction. The rollup overwrites each hour's row, correcting any drift
  # within the hour boundary.
  module HourlyStats
    module_function

    # tuples: each is a Transaction (or anything answering project_id,
    # transaction_name, environment, timestamp, duration, db_time, view_time,
    # query_count, has_n_plus_one, http_status).
    def bump_many!(transactions)
      return if transactions.empty?
      deltas = Hash.new { |h, k| h[k] = new_accumulator }
      transactions.each do |t|
        key = [t.project_id, t.transaction_name, t.environment.to_s, Histogram.hour_bucket(t.timestamp)]
        accumulate!(deltas[key], t)
      end

      conn = TransactionsSpansRecord.connection
      placeholders = []
      binds = []
      deltas.each do |(pid, name, env, hour), a|
        placeholders << "(#{Array.new(COLUMNS.size + 4, "?").join(", ")})"
        binds.push(pid, name, env, hour,
                   a[:count], a[:sum_duration], a[:min_duration], a[:max_duration],
                   a[:sum_db_time], a[:db_time_count], a[:sum_view_time], a[:view_time_count],
                   a[:sum_query_count], a[:max_query_count], a[:n_plus_one_count], a[:error_count])
      end

      sql = +"INSERT INTO transaction_hourly_stats "
      sql << "(project_id, transaction_name, environment, hour_bucket, #{COLUMNS.join(", ")}) VALUES "
      sql << placeholders.join(", ")
      sql << " ON CONFLICT(project_id, transaction_name, environment, hour_bucket) DO UPDATE SET "
      sql << conflict_update_sql
      conn.exec_insert(sql, "hourly_stats bump", binds)
    end

    def bump!(transaction)
      bump_many!([transaction])
    end

    # Order matters: it pins the INSERT column list and the bind order above.
    COLUMNS = %w[
      count sum_duration min_duration max_duration
      sum_db_time db_time_count sum_view_time view_time_count
      sum_query_count max_query_count n_plus_one_count error_count
    ].freeze

    # Additive columns sum on conflict; min/max take the running extreme so the
    # window's min/max stay exact across many bumps and the rollup.
    def conflict_update_sql
      sums = %w[count sum_duration sum_db_time db_time_count sum_view_time
                view_time_count sum_query_count n_plus_one_count error_count]
                .map { |c| "#{c} = #{c} + excluded.#{c}" }
      extremes = [
        "min_duration = MIN(COALESCE(min_duration, excluded.min_duration), excluded.min_duration)",
        "max_duration = MAX(max_duration, excluded.max_duration)",
        "max_query_count = MAX(max_query_count, excluded.max_query_count)"
      ]
      (sums + extremes).join(", ")
    end

    def new_accumulator
      { count: 0, sum_duration: 0, min_duration: nil, max_duration: 0,
        sum_db_time: 0, db_time_count: 0, sum_view_time: 0, view_time_count: 0,
        sum_query_count: 0, max_query_count: 0, n_plus_one_count: 0, error_count: 0 }
    end

    def accumulate!(a, t)
      dur = t.duration.to_i
      a[:count]        += 1
      a[:sum_duration] += dur
      a[:min_duration]  = a[:min_duration].nil? ? dur : [a[:min_duration], dur].min
      a[:max_duration]  = [a[:max_duration], dur].max
      if t.db_time
        a[:sum_db_time]   += t.db_time.to_i
        a[:db_time_count] += 1
      end
      if t.view_time
        a[:sum_view_time]   += t.view_time.to_i
        a[:view_time_count] += 1
      end
      qc = t.query_count.to_i
      a[:sum_query_count] += qc
      a[:max_query_count]  = [a[:max_query_count], qc].max
      a[:n_plus_one_count] += 1 if t.has_n_plus_one
      a[:error_count]      += 1 if t.http_status.to_i >= 500
    end
  end
end
