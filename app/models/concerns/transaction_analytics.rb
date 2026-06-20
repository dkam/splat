module TransactionAnalytics
  extend ActiveSupport::Concern

  class_methods do
    # ---- Volume counts (raw queries on the indexed transactions table). ----

    def count_in_range(time_range:, project_id: nil, environment: nil)
      scope = all
      scope = scope.where(timestamp: time_range)    if time_range
      scope = scope.where(project_id: project_id)   if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope.count
    end

    def total_and_error_count_in_range(time_range:, project_id: nil)
      scope = where(timestamp: time_range)
      scope = scope.where(project_id: project_id) if project_id
      row = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN CAST(http_status AS INTEGER) >= 500 THEN 1 ELSE 0 END)")
      )
      total, errors = row || [0, 0]
      { total: total.to_i, errors: errors.to_i }
    end

    # ---- Aggregate percentiles + simple stats. ----

    def percentiles(time_range, project_id: nil, environment: nil, name_query: nil)
      scope = where(timestamp: time_range)
      scope = scope.where(project_id: project_id)   if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where("transaction_name LIKE ?", "%#{name_query}%") if name_query.present?
      avg, mx, mn, cnt = scope.pick(
        Arel.sql("AVG(duration)"),
        Arel.sql("MAX(duration)"),
        Arel.sql("MIN(duration)"),
        Arel.sql("COUNT(*)")
      ) || [nil, nil, nil, 0]

      pcts = global_percentiles(project_id: project_id, environment: environment, time_range: time_range, name_query: name_query)
      {
        avg:   avg.to_f.round(1),
        max:   mx.to_i,
        min:   mn.to_i,
        count: cnt.to_i,
        p50:   pcts[:p50],
        p95:   pcts[:p95],
        p99:   pcts[:p99]
      }
    end

    # Per-endpoint stats with histogram-backed percentiles.
    def percentiles_for_endpoint(name, time_range, project_id: nil, environment: nil, release: nil)
      scope = where(transaction_name: name).where(timestamp: time_range)
      scope = scope.where(project_id: project_id)   if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(release: release)         if release.present?
      avg_d, avg_db, avg_view, cnt, mx, mn = scope.pick(
        Arel.sql("AVG(duration)"),
        Arel.sql("AVG(db_time)"),
        Arel.sql("AVG(view_time)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("MAX(duration)"),
        Arel.sql("MIN(duration)")
      ) || [nil, nil, nil, 0, nil, nil]

      {
        "transaction_name" => name,
        "avg_duration"     => avg_d.to_f.round(1),
        "avg_db_time"      => avg_db&.to_f&.round(1),
        "avg_view_time"    => avg_view&.to_f&.round(1),
        "count"            => cnt.to_i,
        "max_duration"     => mx.to_i,
        "min_duration"     => mn.to_i,
        # release isn't a dimension on transaction_histograms (high-cardinality;
        # every deploy adds a row per env/endpoint/bucket). When a release filter
        # is set we'd need a raw-row scan to honor it; for now we fall back to the
        # env-only histogram, since release filtering is mainly used by
        # compare_endpoint_performance which already pluck-sorts raw durations.
        "p50_duration"     => histogram_percentile(project_id: project_id, transaction_name: name,
                                                   environment: environment, quantile: 0.50,
                                                   since: time_range.begin, until_time: time_range.end),
        "p95_duration"     => histogram_percentile(project_id: project_id, transaction_name: name,
                                                   environment: environment, quantile: 0.95,
                                                   since: time_range.begin, until_time: time_range.end),
        "p99_duration"     => histogram_percentile(project_id: project_id, transaction_name: name,
                                                   environment: environment, quantile: 0.99,
                                                   since: time_range.begin, until_time: time_range.end)
      }
    end

    # Top endpoints in a window ranked by impact (avg_duration * count).
    # Count/avg/query-stats come from the raw indexed columns in one grouped
    # scan; the histogram-backed p50/p95/p99 are computed only for the returned
    # top-N (≤ limit endpoints × 3 quantiles) so the percentile cost stays bounded.
    def stats_by_endpoint_with_impact(time_range, project_id: nil, environment: nil, name_query: nil, limit: 20)
      scope = where(timestamp: time_range)
      scope = scope.where(project_id: project_id)        if project_id
      scope = scope.where(environment: environment)      if environment.present?
      scope = scope.where("transaction_name LIKE ?", "%#{name_query}%") if name_query.present?

      rows = scope.group(:transaction_name).pluck(
        :transaction_name,
        Arel.sql("AVG(duration)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("MAX(duration)"),
        Arel.sql("AVG(query_count)"),
        Arel.sql("MAX(query_count)"),
        Arel.sql("SUM(CASE WHEN has_n_plus_one THEN 1 ELSE 0 END)")
      )
      ranked = rows.map { |name, avg, count, mx, avg_q, max_q, npo|
        {
          "transaction_name" => name,
          "avg_duration"     => avg.to_f.round(1),
          "count"            => count.to_i,
          "max_duration"     => mx.to_i,
          "time_spent"       => (avg.to_f * count.to_i).round,
          "avg_queries"      => avg_q.to_f.round(1),
          "max_queries"      => max_q.to_i,
          "n_plus_one_count" => npo.to_i
        }
      }.sort_by { |r| -r["time_spent"] }
      ranked = ranked.first(limit) if limit

      ranked.each do |r|
        pcts = endpoint_percentiles(r["transaction_name"], time_range, project_id: project_id, environment: environment)
        r.merge!(pcts)
      end
      ranked
    end

    def stats_by_endpoint(time_range, project_id: nil, limit: 20)
      stats_by_endpoint_with_impact(time_range, project_id: project_id, limit: limit).map do |r|
        { "transaction_name" => r["transaction_name"],
          "avg_duration"     => r["avg_duration"],
          "count"            => r["count"] }
      end
    end

    def endpoints_by_n_plus_one(time_range, project_id: nil, environment: nil, limit: 50)
      base = where(timestamp: time_range)
      base = base.where(project_id: project_id)   if project_id
      base = base.where(environment: environment) if environment.present?

      npo = base.where(has_n_plus_one: true).group(:transaction_name).pluck(
        :transaction_name,
        Arel.sql("COUNT(*)"),
        Arel.sql("AVG(duration)"),
        Arel.sql("MAX(duration)"),
        Arel.sql("AVG(query_count)"),
        Arel.sql("MAX(query_count)")
      )
      return [] if npo.empty?

      # Total requests per affected endpoint (all of them, not just the N+1 ones)
      # so the view can show "N+1 / total" and the affected percentage.
      names  = npo.map(&:first)
      totals = base.where(transaction_name: names).group(:transaction_name).count

      ranked = npo.map { |name, count, avg, mx, avg_q, max_q|
        total = totals[name].to_i
        {
          "transaction_name" => name,
          "n_plus_one_count" => count.to_i,
          "total_count"      => total,
          "n_plus_one_pct"   => total.zero? ? 0 : ((count.to_f / total) * 100).round(1),
          "avg_duration"     => avg.to_f.round(1),
          "max_duration"     => mx.to_i,
          "avg_queries"      => avg_q.to_f.round(1),
          "max_queries"      => max_q.to_i
        }
      }.sort_by { |r| -r["n_plus_one_count"] }.first(limit)

      ranked.each do |r|
        pcts = endpoint_percentiles(r["transaction_name"], time_range, project_id: project_id, environment: environment)
        r.merge!(pcts)
      end
      ranked
    end

    def slow(time_range:, project_id: nil, threshold_ms: 1000, environment: nil, http_status: nil,
             http_method: nil, transaction_name: nil, tags: nil, limit: 100)
      scope = where(timestamp: time_range).where("duration > ?", threshold_ms)
      scope = scope.where(project_id: project_id)             if project_id
      scope = scope.where(environment: environment)           if environment.present?
      scope = scope.where(http_status: http_status)           if http_status.present?
      scope = scope.where(http_method: http_method)           if http_method.present?
      # endpoint is advertised as a case-insensitive substring match (LIKE is
      # case-insensitive for ASCII in SQLite), not exact equality.
      scope = scope.where("transaction_name LIKE ?", "%#{transaction_name}%") if transaction_name.present?
      # Push tag predicates into SQL via json_extract so LIMIT applies to
      # the post-filter set. Key allowlist is enforced upstream
      # (mcp_controller#search_slow_transactions); we still bind the value.
      if tags.present?
        tags.each do |k, v|
          scope = scope.where("json_extract(tags, ?) = ?", "$.#{k}", v.to_s)
        end
      end
      scope.order(duration: :desc).limit(limit).to_a
    end

    # ---- Bucketed time series (for sparklines + charts). ----

    # p95 per bucket per endpoint. Bucket size = (window / buckets).
    # If bucket aligns to an hour boundary AND the rollup has run, we can
    # use the histogram directly. For arbitrary bucket sizes / live data,
    # we fall back to a sorted-duration pluck per bucket — fast enough for
    # 20 endpoints × 24 buckets on the indexed table.
    def p95_by_bucket(transaction_names:, time_range:, buckets:, project_id: nil, environment: nil)
      return {} if transaction_names.empty?
      window  = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)

      rows = where(transaction_name: transaction_names)
             .where(timestamp: time_range)
      rows = rows.where(project_id: project_id)   if project_id
      rows = rows.where(environment: environment) if environment.present?
      rows = rows.pluck(:transaction_name,
                        Arel.sql("CAST((strftime('%s', timestamp) - #{time_range.begin.to_i}) / #{bucket_seconds} AS INTEGER)"),
                        :duration)

      grouped = rows.group_by { |name, idx, _| [name, idx] }
                    .transform_values { |entries| entries.map { |e| e[2] } }
      transaction_names.each_with_object({}) do |name, result|
        result[name] = Array.new(buckets, 0)
        (0...buckets).each do |b|
          durs = grouped[[name, b]] || []
          next if durs.empty?
          sorted = durs.sort
          result[name][b] = sorted[(sorted.size * 0.95).floor]
        end
      end
    end

    # Total volume bucketed by time.
    def volume_by_bucket(project_id:, time_range:, buckets:, environment: nil)
      window         = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)

      rows = where(timestamp: time_range)
      rows = rows.where(project_id: project_id)   if project_id
      rows = rows.where(environment: environment) if environment.present?

      counts = rows.group(Arel.sql("CAST((strftime('%s', timestamp) - #{time_range.begin.to_i}) / #{bucket_seconds} AS INTEGER)")).count

      Array.new(buckets, 0).tap do |result|
        counts.each do |idx, c|
          i = idx.to_i
          result[i] = c if i >= 0 && i < buckets
        end
      end
    end

    def time_series_for_endpoint(name, time_range, project_id: nil, buckets: 24, bucket_count: nil, environment: nil, release: nil)
      buckets = bucket_count if bucket_count
      window         = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)
      scope = where(transaction_name: name).where(timestamp: time_range)
      scope = scope.where(project_id: project_id)   if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(release: release)         if release.present?

      rows = scope.pluck(
        Arel.sql("CAST((strftime('%s', timestamp) - #{time_range.begin.to_i}) / #{bucket_seconds} AS INTEGER)"),
        :duration
      )
      grouped = rows.group_by(&:first).transform_values { |entries| entries.map(&:last).sort }
      Array.new(buckets) do |b|
        durs = grouped[b] || []
        if durs.empty?
          { "bucket" => b, "count" => 0, "p50" => nil, "p95" => nil, "p99" => nil }
        else
          {
            "bucket" => b,
            "count"  => durs.size,
            "p50"    => durs[(durs.size * 0.50).floor],
            "p95"    => durs[(durs.size * 0.95).floor],
            "p99"    => durs[(durs.size * 0.99).floor]
          }
        end
      end
    end

    def response_time_by_hour(time_range, project_id: nil)
      time_series_for_endpoint_global(time_range, project_id: project_id, buckets: 24)
    end

    private

    # Histogram-backed p50/p95/p99 for one endpoint over a window, keyed to
    # match the dashboard/MCP consumers (p50_duration/p95_duration/p99_duration).
    def endpoint_percentiles(name, time_range, project_id:, environment:)
      {
        "p50_duration" => histogram_percentile(project_id: project_id, transaction_name: name,
                                               environment: environment, quantile: 0.50,
                                               since: time_range.begin, until_time: time_range.end),
        "p95_duration" => histogram_percentile(project_id: project_id, transaction_name: name,
                                               environment: environment, quantile: 0.95,
                                               since: time_range.begin, until_time: time_range.end),
        "p99_duration" => histogram_percentile(project_id: project_id, transaction_name: name,
                                               environment: environment, quantile: 0.99,
                                               since: time_range.begin, until_time: time_range.end)
      }
    end

    # Aggregate percentile across endpoints. With no name_query it merges every
    # endpoint name; name_query scopes it via the transaction_name dimension the
    # histogram already carries (so a name-filtered dashboard header matches its
    # table). project_id/name/env are bound only when present — `project_id = ?`
    # with NULL matches nothing, and a conditional bind is sargable where the old
    # COALESCE(?, project_id) was not.
    # Returns { p50:, p95:, p99: } in ms (nil where there's no data). All three
    # quantiles come from ONE pass over the merge CTE — the running cumulative is
    # built once and each quantile is a scalar subquery over it (the 0.50/0.95/
    # 0.99 constants are literals, not user input). This replaces three separate
    # CTE evaluations per call.
    def global_percentiles(project_id:, environment:, time_range:, name_query: nil)
      hour_start = Analytics::Histogram.hour_bucket(time_range.begin)
      until_hour = Analytics::Histogram.hour_bucket(time_range.end)
      proj_filter = project_id.present?  ? "AND project_id = ?" : ""
      name_filter = name_query.present?  ? "AND transaction_name LIKE ?" : ""
      env_filter  = environment.present? ? "AND environment = ?" : ""
      sql = <<~SQL
        WITH merged AS (
          SELECT bucket_index, SUM(count) AS c
            FROM transaction_histograms
           WHERE hour_bucket >= ? AND hour_bucket < ?
             #{proj_filter}
             #{name_filter}
             #{env_filter}
           GROUP BY bucket_index
          UNION ALL
          SELECT CAST(FLOOR(LN(MAX(duration, 1)) / LN(?)) AS INTEGER) AS bucket_index,
                 COUNT(*) AS c
            FROM transactions
           WHERE timestamp >= ? AND timestamp < ?
             #{proj_filter}
             #{name_filter}
             #{env_filter}
           GROUP BY 1
        ), reduced AS (
          SELECT bucket_index, SUM(c) AS c FROM merged GROUP BY bucket_index
        ), running AS (
          SELECT bucket_index, c,
                 SUM(c) OVER (ORDER BY bucket_index) AS cum,
                 SUM(c) OVER () AS total
            FROM reduced
        )
        SELECT
          (SELECT bucket_index FROM running WHERE cum >= 0.50 * total ORDER BY bucket_index LIMIT 1),
          (SELECT bucket_index FROM running WHERE cum >= 0.95 * total ORDER BY bucket_index LIMIT 1),
          (SELECT bucket_index FROM running WHERE cum >= 0.99 * total ORDER BY bucket_index LIMIT 1)
      SQL
      # See Transaction.histogram_percentile: clamp raw-branch lower bound so
      # a sub-hour window doesn't pull rows from before time_range.begin.
      raw_lower = [time_range.begin, until_hour].max
      like = "%#{name_query}%" if name_query.present?
      binds = [hour_start, until_hour]
      binds << project_id  if project_id.present?
      binds << like        if name_query.present?
      binds << environment if environment.present?
      binds << Analytics::Histogram::GAMMA
      binds.push(raw_lower, time_range.end)
      binds << project_id  if project_id.present?
      binds << like        if name_query.present?
      binds << environment if environment.present?

      row = connection.select_rows(sanitize_sql_array([sql, *binds])).first || []
      p50, p95, p99 = row
      {
        p50: p50 && Analytics::Histogram.index_to_ms(p50.to_i),
        p95: p95 && Analytics::Histogram.index_to_ms(p95.to_i),
        p99: p99 && Analytics::Histogram.index_to_ms(p99.to_i)
      }
    end

    def time_series_for_endpoint_global(time_range, project_id:, buckets:)
      window         = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)
      scope = where(timestamp: time_range)
      scope = scope.where(project_id: project_id) if project_id

      rows = scope.pluck(
        Arel.sql("CAST((strftime('%s', timestamp) - #{time_range.begin.to_i}) / #{bucket_seconds} AS INTEGER)"),
        :duration
      )
      grouped = rows.group_by(&:first).transform_values { |entries| entries.map(&:last).sort }
      Array.new(buckets) do |b|
        durs = grouped[b] || []
        avg = durs.empty? ? 0 : (durs.sum.to_f / durs.size).round(1)
        { "bucket" => b, "count" => durs.size, "avg_duration" => avg }
      end
    end
  end
end
