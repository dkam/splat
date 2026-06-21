module Analytics
  # Log-bucketing math for the DDSketch-style mergeable percentile path.
  # GAMMA = 1.02 buckets are ~2% wide; reconstructing at the bucket midpoint
  # (see index_to_ms) gives a centered ±1% relative error for latency views.
  module Histogram
    GAMMA = 1.02
    LN_GAMMA = Math.log(GAMMA)

    module_function

    # Integer bucket index for a duration in ms. Saturates at 1 ms minimum
    # so 0-duration rows still pick a real bucket.
    def bucket_index(duration_ms)
      d = [duration_ms.to_i, 1].max
      (Math.log(d) / LN_GAMMA).floor
    end

    # Bucket `index` covers durations [GAMMA**index, GAMMA**(index+1)) because
    # bucket_index floors. Reconstruct at the geometric midpoint so the error is
    # centered (±~1%) instead of biased low by up to GAMMA-1 (~2%) — returning
    # the lower edge would report every percentile ~1% faster than reality.
    def index_to_ms(index)
      GAMMA**(index + 0.5)
    end

    # SQL counterpart of bucket_index: the integer DDSketch bucket for a duration
    # column. GAMMA is a constant, inlined as a literal (no bind). This is the one
    # place the writer (rollup) and reader (percentile queries) share the formula,
    # so they can't drift.
    def bucket_index_sql(duration_column = "duration")
      "CAST(FLOOR(LN(MAX(#{duration_column}, 1)) / LN(#{GAMMA})) AS INTEGER)"
    end

    # SQL bucketing a timestamp column into integer indices over a window:
    # floor((epoch(column) - origin) / bucket_seconds). origin_epoch and
    # bucket_seconds are integers computed in Ruby (safe to interpolate).
    def time_bucket_sql(origin_epoch:, bucket_seconds:, column: "timestamp")
      "CAST((strftime('%s', #{column}) - #{origin_epoch.to_i}) / #{bucket_seconds.to_i} AS INTEGER)"
    end

    # Reduce a {bucket_index => count} distribution to a percentile (ms) via the
    # bucket midpoint. This is THE percentile algorithm — the per-bucket time
    # series (sparklines) and the release-filtered raw fallback both call it, and
    # it matches the cumulative-threshold logic SQL'd inline in
    # TransactionAnalytics#merged_percentiles (cum >= q*total → index_to_ms), so
    # every percentile in the app is computed one way. `q` is a fraction (0.95).
    def percentile_from_counts(counts_by_index, q)
      total = counts_by_index.values.sum
      return nil if total.zero?
      threshold = q * total
      cum = 0
      counts_by_index.keys.sort.each do |idx|
        cum += counts_by_index[idx]
        return index_to_ms(idx) if cum >= threshold
      end
      nil
    end

    # Hour-aligned UTC datetime for a timestamp. Used as hour_bucket value.
    def hour_bucket(timestamp)
      t = timestamp.is_a?(Time) ? timestamp : Time.parse(timestamp.to_s)
      Time.utc(t.utc.year, t.utc.month, t.utc.day, t.utc.hour)
    end

    # Live increment for the in-progress hour. Idempotent it is NOT (each
    # call adds 1) — only call once per transaction inserted. The hourly
    # rollup job overwrites the row via excluded.count, so any drift gets
    # corrected within the hour boundary.
    def bump!(project_id:, transaction_name:, environment:, timestamp:, duration_ms:)
      bump_many!([[project_id, transaction_name, environment, timestamp, duration_ms]])
    end

    # Batched form for ingest consumers — collapses N transactions into a
    # single multi-row INSERT ... ON CONFLICT DO UPDATE count = count + N.
    # Each tuple is [project_id, transaction_name, environment, timestamp, duration_ms].
    def bump_many!(tuples)
      return if tuples.empty?
      deltas = Hash.new(0)
      tuples.each do |(pid, name, env, ts, dur)|
        key = [pid, name, env.to_s, hour_bucket(ts), bucket_index(dur)]
        deltas[key] += 1
      end

      conn = TransactionsSpansRecord.connection
      sql = +"INSERT INTO transaction_histograms (project_id, transaction_name, environment, hour_bucket, bucket_index, count) VALUES "
      placeholders = []
      binds = []
      deltas.each do |(pid, name, env, hour, bucket), delta|
        placeholders << "(?, ?, ?, ?, ?, ?)"
        binds.push(pid, name, env, hour, bucket, delta)
      end
      sql << placeholders.join(", ")
      sql << " ON CONFLICT(project_id, transaction_name, environment, hour_bucket, bucket_index)"
      sql << " DO UPDATE SET count = count + excluded.count"
      conn.exec_insert(sql, "histogram bump", binds)
    end
  end
end
