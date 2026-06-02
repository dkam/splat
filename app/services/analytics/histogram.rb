module Analytics
  # Log-bucketing math for the DDSketch-style mergeable percentile path.
  # GAMMA = 1.02 gives ~2% relative error, which is plenty for latency views.
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

    def index_to_ms(index)
      GAMMA**index
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
    def bump!(project_id:, transaction_name:, timestamp:, duration_ms:)
      bump_many!([[project_id, transaction_name, timestamp, duration_ms]])
    end

    # Batched form for ingest consumers — collapses N transactions into a
    # single multi-row INSERT ... ON CONFLICT DO UPDATE count = count + N.
    def bump_many!(tuples)
      return if tuples.empty?
      deltas = Hash.new(0)
      tuples.each do |(pid, name, ts, dur)|
        key = [pid, name, hour_bucket(ts), bucket_index(dur)]
        deltas[key] += 1
      end

      conn = TransactionsSpansRecord.connection
      sql = +"INSERT INTO transaction_histograms (project_id, transaction_name, hour_bucket, bucket_index, count) VALUES "
      placeholders = []
      binds = []
      deltas.each do |(pid, name, hour, bucket), delta|
        placeholders << "(?, ?, ?, ?, ?)"
        binds.push(pid, name, hour, bucket, delta)
      end
      sql << placeholders.join(", ")
      sql << " ON CONFLICT(project_id, transaction_name, hour_bucket, bucket_index)"
      sql << " DO UPDATE SET count = count + excluded.count"
      conn.exec_insert(sql, "histogram bump", binds)
    end
  end
end
