module TransactionAnalytics
  extend ActiveSupport::Concern

  # Aggregate SELECT list for transaction_hourly_stats reads. Defined at module
  # level (not inside `class_methods`) so it's a real constant rather than one
  # redefined each time the block evaluates; it still resolves lexically from the
  # class methods below. Window covers whole hours [hour(begin) .. hour(end)]
  # inclusive — the end hour is the in-progress one (kept current by the live
  # ingest bump); the begin hour over-includes up to ~1h of pre-window rows.
  HOURLY_AGG = <<~SQL.squish.freeze
    COALESCE(SUM(count), 0)            AS count,
    COALESCE(SUM(sum_duration), 0)     AS sum_duration,
    MIN(min_duration)                  AS min_duration,
    COALESCE(MAX(max_duration), 0)     AS max_duration,
    COALESCE(SUM(sum_db_time), 0)      AS sum_db_time,
    COALESCE(SUM(db_time_count), 0)    AS db_time_count,
    COALESCE(SUM(sum_view_time), 0)    AS sum_view_time,
    COALESCE(SUM(view_time_count), 0)  AS view_time_count,
    COALESCE(SUM(sum_query_count), 0)  AS sum_query_count,
    COALESCE(MAX(max_query_count), 0)  AS max_query_count,
    COALESCE(SUM(n_plus_one_count), 0) AS n_plus_one_count,
    COALESCE(SUM(error_count), 0)      AS error_count
  SQL

  # All windowed analytics read from the two hourly aggregate tables rather than
  # the raw `transactions` table:
  #   * transaction_hourly_stats — count / sums / max / min / query / N+1 / 5xx
  #   * transaction_histograms   — per-bucket duration counts (percentiles)
  # Both are kept far longer than the raw rows (see Maintenance::RetentionJob),
  # so endpoint stats and the latency/volume sparklines keep working — and stay
  # cheap — even for windows whose raw transactions have aged out. The live
  # ingest bumps keep the in-progress hour fresh, so reads never touch raw.
  #
  # Percentiles are computed exactly one way everywhere: the DDSketch midpoint
  # reconstruction in Analytics::Histogram (merged_percentiles does it inline in
  # SQL; the per-bucket series and the release-filtered raw fallback call
  # Analytics::Histogram.percentile_from_counts). No more sort-the-durations path.
  #
  # The `release` dimension isn't carried on either aggregate table (it's
  # high-cardinality — a row per deploy × endpoint × env × hour). The handful of
  # release-filtered readers (MCP, ≤7-day windows) fall back to a bounded raw
  # scan; everything else uses the aggregates.
  class_methods do
    # ---- Volume / error counts. ----

    def count_in_range(time_range:, project_id: nil, environment: nil)
      return hourly_stats_row(time_range: time_range, project_id: project_id, environment: environment)[:count] if time_range

      scope = all
      scope = scope.where(project_id: project_id) if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope.count
    end

    def total_and_error_count_in_range(time_range:, project_id: nil)
      row = hourly_stats_row(time_range: time_range, project_id: project_id)
      {total: row[:count], errors: row[:error_count]}
    end

    # ---- Aggregate percentiles + simple stats. ----

    def percentiles(time_range, project_id: nil, environment: nil, name_query: nil)
      row = hourly_stats_row(time_range: time_range, project_id: project_id, environment: environment, name_query: name_query)
      pcts = merged_percentiles(time_range: time_range, project_id: project_id, environment: environment, name_query: name_query)
      cnt = row[:count]
      {
        avg: cnt.zero? ? 0.0 : (row[:sum_duration].to_f / cnt).round(1),
        max: row[:max_duration],
        min: row[:min_duration].to_i,
        count: cnt,
        p50: pcts[:p50],
        p95: pcts[:p95],
        p99: pcts[:p99]
      }
    end

    # Per-endpoint stats with histogram-backed percentiles. A `release` filter
    # falls back to a bounded raw scan (the aggregates don't carry release).
    def percentiles_for_endpoint(name, time_range, project_id: nil, environment: nil, release: nil)
      return percentiles_for_endpoint_raw(name, time_range, project_id: project_id, environment: environment, release: release) if release.present?

      row = hourly_stats_row(time_range: time_range, project_id: project_id, environment: environment, transaction_name: name)
      pcts = merged_percentiles(time_range: time_range, project_id: project_id, environment: environment, transaction_name: name)
      cnt = row[:count]
      {
        "transaction_name" => name,
        "avg_duration" => cnt.zero? ? 0.0 : (row[:sum_duration].to_f / cnt).round(1),
        "avg_db_time" => row[:db_time_count].zero? ? nil : (row[:sum_db_time].to_f / row[:db_time_count]).round(1),
        "avg_view_time" => row[:view_time_count].zero? ? nil : (row[:sum_view_time].to_f / row[:view_time_count]).round(1),
        "count" => cnt,
        "max_duration" => row[:max_duration],
        "min_duration" => row[:min_duration].to_i,
        "p50_duration" => pcts[:p50],
        "p95_duration" => pcts[:p95],
        "p99_duration" => pcts[:p99]
      }
    end

    # Top endpoints in a window ranked by impact (avg_duration * count). All
    # scalar stats come from one grouped scan of transaction_hourly_stats; the
    # histogram-backed p50/p95/p99 are computed only for the returned top-N.
    def stats_by_endpoint_with_impact(time_range, project_id: nil, environment: nil, name_query: nil, limit: 20)
      ranked = hourly_stats_grouped(time_range: time_range, project_id: project_id, environment: environment, name_query: name_query).map do |r|
        cnt = r["count"].to_i
        avg = cnt.zero? ? 0.0 : (r["sum_duration"].to_f / cnt)
        {
          "transaction_name" => r["transaction_name"],
          "avg_duration" => avg.round(1),
          "count" => cnt,
          "max_duration" => r["max_duration"].to_i,
          "time_spent" => (avg * cnt).round,
          "avg_queries" => cnt.zero? ? 0.0 : (r["sum_query_count"].to_f / cnt).round(1),
          "max_queries" => r["max_query_count"].to_i,
          "n_plus_one_count" => r["n_plus_one_count"].to_i
        }
      end.sort_by { |r| -r["time_spent"] }
      ranked = ranked.first(limit) if limit

      ranked.each do |r|
        r.merge!(endpoint_percentiles(r["transaction_name"], time_range, project_id: project_id, environment: environment))
      end
      ranked
    end

    def stats_by_endpoint(time_range, project_id: nil, limit: 20)
      stats_by_endpoint_with_impact(time_range, project_id: project_id, limit: limit).map do |r|
        {"transaction_name" => r["transaction_name"],
         "avg_duration" => r["avg_duration"],
         "count" => r["count"]}
      end
    end

    def endpoints_by_n_plus_one(time_range, project_id: nil, environment: nil, limit: 50)
      rows = hourly_stats_grouped(time_range: time_range, project_id: project_id, environment: environment)
        .select { |r| r["n_plus_one_count"].to_i.positive? }
      return [] if rows.empty?

      ranked = rows.map do |r|
        cnt = r["count"].to_i
        npo = r["n_plus_one_count"].to_i
        {
          "transaction_name" => r["transaction_name"],
          "n_plus_one_count" => npo,
          # count on the hourly row is total requests for the endpoint, so the
          # affected percentage no longer needs a separate totals query.
          "total_count" => cnt,
          "n_plus_one_pct" => cnt.zero? ? 0 : ((npo.to_f / cnt) * 100).round(1),
          "avg_duration" => cnt.zero? ? 0.0 : (r["sum_duration"].to_f / cnt).round(1),
          "max_duration" => r["max_duration"].to_i,
          "avg_queries" => cnt.zero? ? 0.0 : (r["sum_query_count"].to_f / cnt).round(1),
          "max_queries" => r["max_query_count"].to_i
        }
      end.sort_by { |r| -r["n_plus_one_count"] }.first(limit)

      ranked.each do |r|
        r.merge!(endpoint_percentiles(r["transaction_name"], time_range, project_id: project_id, environment: environment))
      end
      ranked
    end

    def slow(time_range:, project_id: nil, threshold_ms: 1000, environment: nil, http_status: nil,
      http_method: nil, transaction_name: nil, tags: nil, limit: 100)
      scope = where(timestamp: time_range).where("duration > ?", threshold_ms)
      scope = scope.where(project_id: project_id) if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(http_status: http_status) if http_status.present?
      scope = scope.where(http_method: http_method) if http_method.present?
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
    #
    # All three read pre-aggregated rows: hour-aligned bucket sizes (the common
    # 24h/24-bucket dashboard case and any multi-hour bucket) read the histogram
    # / hourly_stats tables directly; sub-hour buckets (windows shorter than the
    # bucket count, e.g. 1h/6h) fold the same DDSketch buckets out of raw in one
    # bounded GROUP BY. No path pulls per-row durations into Ruby.

    # p95 per bucket per endpoint → { name => Array(buckets) of p95 ms }.
    def p95_by_bucket(transaction_names:, time_range:, buckets:, project_id: nil, environment: nil)
      return {} if transaction_names.empty?
      by_name = bucketed_index_counts(
        time_range: time_range, buckets: buckets, project_id: project_id,
        environment: environment, transaction_names: transaction_names, include_name: true
      )
      transaction_names.each_with_object({}) do |name, result|
        series = by_name[name] || {}
        result[name] = Array.new(buckets) do |b|
          counts = series[b]
          (counts && counts.any?) ? (Analytics::Histogram.percentile_from_counts(counts, 0.95) || 0).round : 0
        end
      end
    end

    # Total transaction volume bucketed by time.
    def volume_by_bucket(project_id:, time_range:, buckets:, environment: nil)
      rows = bucketed_volume(time_range: time_range, buckets: buckets, project_id: project_id, environment: environment)
      Array.new(buckets, 0).tap do |result|
        rows.each { |b, r| result[b] = r[:count] if b >= 0 && b < buckets }
      end
    end

    def time_series_for_endpoint(name, time_range, project_id: nil, buckets: 24, bucket_count: nil, environment: nil, release: nil)
      buckets = bucket_count if bucket_count
      series = bucketed_index_counts(
        time_range: time_range, buckets: buckets, project_id: project_id,
        environment: environment, transaction_name: name, release: release
      )
      Array.new(buckets) do |b|
        counts = series[b]
        if counts.nil? || counts.empty?
          {"bucket" => b, "count" => 0, "p50" => nil, "p95" => nil, "p99" => nil}
        else
          {
            "bucket" => b,
            "count" => counts.values.sum,
            "p50" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.50)),
            "p95" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.95)),
            "p99" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.99))
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
      pcts = merged_percentiles(time_range: time_range, project_id: project_id, environment: environment, transaction_name: name)
      {
        "p50_duration" => pcts[:p50],
        "p95_duration" => pcts[:p95],
        "p99_duration" => pcts[:p99]
      }
    end

    def round_or_nil(value)
      value&.round
    end

    # ---- transaction_hourly_stats scalar reads. ----

    def hourly_stats_row(time_range:, project_id: nil, environment: nil, transaction_name: nil, name_query: nil)
      where_sql, binds = hourly_filters(time_range: time_range, project_id: project_id, environment: environment,
        transaction_name: transaction_name, name_query: name_query)
      sql = "SELECT #{HOURLY_AGG} FROM transaction_hourly_stats WHERE #{where_sql}"
      r = connection.select_one(sanitize_sql_array([sql, *binds])) || {}
      symbolize_hourly_row(r)
    end

    def hourly_stats_grouped(time_range:, project_id: nil, environment: nil, name_query: nil)
      where_sql, binds = hourly_filters(time_range: time_range, project_id: project_id, environment: environment,
        name_query: name_query)
      sql = "SELECT transaction_name, #{HOURLY_AGG} FROM transaction_hourly_stats WHERE #{where_sql} GROUP BY transaction_name"
      connection.select_all(sanitize_sql_array([sql, *binds])).to_a
    end

    def symbolize_hourly_row(r)
      {
        count: r["count"].to_i,
        sum_duration: r["sum_duration"].to_i,
        min_duration: r["min_duration"], # nil when no rows
        max_duration: r["max_duration"].to_i,
        sum_db_time: r["sum_db_time"].to_i,
        db_time_count: r["db_time_count"].to_i,
        sum_view_time: r["sum_view_time"].to_i,
        view_time_count: r["view_time_count"].to_i,
        sum_query_count: r["sum_query_count"].to_i,
        max_query_count: r["max_query_count"].to_i,
        n_plus_one_count: r["n_plus_one_count"].to_i,
        error_count: r["error_count"].to_i
      }
    end

    def hourly_filters(time_range:, project_id:, environment:, transaction_name: nil, name_query: nil)
      lo = Analytics::Histogram.hour_bucket(time_range.begin)
      hi = Analytics::Histogram.hour_bucket(time_range.end)
      clauses = ["hour_bucket >= ?", "hour_bucket <= ?"]
      binds = [lo, hi]
      if project_id
        clauses << "project_id = ?"
        binds << project_id
      end
      if transaction_name
        clauses << "transaction_name = ?"
        binds << transaction_name
      elsif name_query.present?
        clauses << "transaction_name LIKE ?"
        binds << "%#{name_query}%"
      end
      if environment.present?
        clauses << "environment = ?"
        binds << environment
      end
      [clauses.join(" AND "), binds]
    end

    # Bounded raw fallback for a release-filtered endpoint summary (aggregates
    # don't carry release). Percentiles use the same DDSketch reducer as
    # everything else, so the algorithm stays unified.
    def percentiles_for_endpoint_raw(name, time_range, project_id:, environment:, release:)
      scope = where(transaction_name: name).where(timestamp: time_range)
      scope = scope.where(project_id: project_id) if project_id
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(release: release) if release.present?
      avg_d, avg_db, avg_view, cnt, mx, mn = scope.pick(
        Arel.sql("AVG(duration)"), Arel.sql("AVG(db_time)"), Arel.sql("AVG(view_time)"),
        Arel.sql("COUNT(*)"), Arel.sql("MAX(duration)"), Arel.sql("MIN(duration)")
      ) || [nil, nil, nil, 0, nil, nil]
      counts = raw_index_counts(scope)
      {
        "transaction_name" => name,
        "avg_duration" => avg_d.to_f.round(1),
        "avg_db_time" => avg_db&.to_f&.round(1),
        "avg_view_time" => avg_view&.to_f&.round(1),
        "count" => cnt.to_i,
        "max_duration" => mx.to_i,
        "min_duration" => mn.to_i,
        "p50_duration" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.50)),
        "p95_duration" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.95)),
        "p99_duration" => round_or_nil(Analytics::Histogram.percentile_from_counts(counts, 0.99))
      }
    end

    # { ddsketch_bucket_index => count } for a raw scope.
    def raw_index_counts(scope)
      scope.group(Arel.sql(Analytics::Histogram.bucket_index_sql)).count.transform_keys(&:to_i)
    end

    # ---- Per-time-bucket DDSketch index counts (the percentile sparkline core). ----

    # Returns either { time_bucket => { ddsketch_index => count } } or, with
    # include_name, { name => { time_bucket => { ddsketch_index => count } } }.
    # Reads transaction_histograms for hour-aligned bucket sizes; raw transactions
    # for sub-hour sizes or when a release filter is set (release isn't on the
    # histogram). Both branches share the same filter columns and feed the same
    # Analytics::Histogram.percentile_from_counts reducer.
    def bucketed_index_counts(time_range:, buckets:, project_id: nil, environment: nil,
      transaction_name: nil, transaction_names: nil, include_name: false, release: nil)
      window = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)
      origin = time_range.begin.to_i
      use_histogram = (bucket_seconds % 3600).zero? && release.blank?

      if use_histogram
        source = "transaction_histograms"
        time_col = "hour_bucket"
        index_expr = "bucket_index"
        count_expr = "SUM(count)"
      else
        source = "transactions"
        time_col = "timestamp"
        index_expr = Analytics::Histogram.bucket_index_sql
        count_expr = "COUNT(*)"
      end

      tb = Analytics::Histogram.time_bucket_sql(origin_epoch: origin, bucket_seconds: bucket_seconds, column: time_col)
      name_select = include_name ? "transaction_name AS name, " : ""
      name_group = include_name ? "name, " : ""

      where_sql, binds = bucket_filters(
        source: source, time_col: time_col, time_range: time_range,
        project_id: project_id, environment: environment,
        transaction_name: transaction_name, transaction_names: transaction_names, release: release
      )

      sql = "SELECT #{name_select}#{tb} AS tb, #{index_expr} AS bi, #{count_expr} AS c " \
            "FROM #{source} WHERE #{where_sql} GROUP BY #{name_group}tb, bi"
      rows = connection.select_rows(sanitize_sql_array([sql, *binds]))

      fold_bucketed_rows(rows, buckets: buckets, include_name: include_name)
    end

    def fold_bucketed_rows(rows, buckets:, include_name:)
      result = {}
      rows.each do |row|
        if include_name
          name, tb, bi, c = row
        else
          tb, bi, c = row
        end
        i = tb.to_i
        next if i.negative? || i >= buckets
        bucket_map = include_name ? (result[name] ||= {}) : result
        (bucket_map[i] ||= Hash.new(0))[bi.to_i] += c.to_i
      end
      result
    end

    # Per-time-bucket volume (+ duration sum) for the count/avg charts.
    # { time_bucket => { count:, sum: } }. Hour-aligned → hourly_stats; sub-hour
    # → raw. Mirrors bucketed_index_counts' source-selection.
    def bucketed_volume(time_range:, buckets:, project_id: nil, environment: nil)
      window = time_range.end - time_range.begin
      bucket_seconds = (window / buckets).to_i.clamp(1, nil)
      origin = time_range.begin.to_i

      if (bucket_seconds % 3600).zero?
        source, time_col = "transaction_hourly_stats", "hour_bucket"
        count_expr, sum_expr = "COALESCE(SUM(count), 0)", "COALESCE(SUM(sum_duration), 0)"
      else
        source, time_col = "transactions", "timestamp"
        count_expr, sum_expr = "COUNT(*)", "COALESCE(SUM(duration), 0)"
      end

      tb = Analytics::Histogram.time_bucket_sql(origin_epoch: origin, bucket_seconds: bucket_seconds, column: time_col)
      where_sql, binds = bucket_filters(
        source: source, time_col: time_col, time_range: time_range,
        project_id: project_id, environment: environment
      )

      sql = "SELECT #{tb} AS tb, #{count_expr} AS c, #{sum_expr} AS s FROM #{source} WHERE #{where_sql} GROUP BY tb"
      connection.select_rows(sanitize_sql_array([sql, *binds])).each_with_object({}) do |(tb_idx, c, s), acc|
        i = tb_idx.to_i
        next if i.negative? || i >= buckets
        acc[i] = {count: c.to_i, sum: s.to_i}
      end
    end

    # Shared WHERE for the bucketed readers. For aggregate sources the time
    # column is hour_bucket and the upper bound is inclusive of the current hour
    # (live-bumped); for raw it's the half-open [begin, end) timestamp window.
    def bucket_filters(source:, time_col:, time_range:, project_id: nil, environment: nil,
      transaction_name: nil, transaction_names: nil, release: nil)
      aggregate = (time_col == "hour_bucket")
      if aggregate
        clauses = ["#{time_col} >= ?", "#{time_col} <= ?"]
        binds = [Analytics::Histogram.hour_bucket(time_range.begin), Analytics::Histogram.hour_bucket(time_range.end)]
      else
        clauses = ["#{time_col} >= ?", "#{time_col} < ?"]
        binds = [time_range.begin, time_range.end]
      end
      if project_id
        clauses << "project_id = ?"
        binds << project_id
      end
      if transaction_names
        clauses << "transaction_name IN (#{(["?"] * transaction_names.size).join(", ")})"
        binds.concat(transaction_names)
      elsif transaction_name
        clauses << "transaction_name = ?"
        binds << transaction_name
      end
      if environment.present?
        clauses << "environment = ?"
        binds << environment
      end
      if release.present? # only ever set on the raw source
        clauses << "release = ?"
        binds << release
      end
      [clauses.join(" AND "), binds]
    end

    # Aggregate percentile across endpoints. With no name_query it merges every
    # endpoint name; name_query scopes it via the transaction_name dimension the
    # histogram already carries (so a name-filtered dashboard header matches its
    # table). project_id/name/env are bound only when present — `project_id = ?`
    # with NULL matches nothing, and a conditional bind is sargable where the old
    # COALESCE(?, project_id) was not.
    # The single mergeable-percentile reader. Returns { p50:, p95:, p99: } in ms
    # (nil where there's no data) for the given window, merging pre-computed
    # transaction_histograms rows with the in-progress hour unioned from raw
    # transactions. One CTE pass: the running cumulative is built once and each
    # quantile is a scalar subquery over it (0.50/0.95/0.99 are literals).
    #
    # Name scoping: pass transaction_name for an exact endpoint, or name_query
    # for a substring (LIKE) match across endpoints; omit both for project-wide.
    # transaction_histograms stores env as '' for NULL-env sources, so an explicit
    # environment filter never matches the no-env bucket (by design).
    def merged_percentiles(time_range:, project_id: nil, environment: nil, transaction_name: nil, name_query: nil)
      hour_start = Analytics::Histogram.hour_bucket(time_range.begin)
      until_hour = Analytics::Histogram.hour_bucket(time_range.end)
      proj_filter = project_id.present? ? "AND project_id = ?" : ""
      env_filter = environment.present? ? "AND environment = ?" : ""
      name_filter =
        if transaction_name.present? then "AND transaction_name = ?"
        elsif name_query.present? then "AND transaction_name LIKE ?"
        else ""
        end
      name_bind = transaction_name.presence || ("%#{name_query}%" if name_query.present?)
      bucket_sql = Analytics::Histogram.bucket_index_sql

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
          SELECT #{bucket_sql} AS bucket_index, COUNT(*) AS c
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
      # Clamp the raw-branch lower bound to the later of time_range.begin and the
      # window's last hour so a sub-hour window doesn't pull pre-window rows.
      raw_lower = [time_range.begin, until_hour].max
      binds = [hour_start, until_hour]
      binds << project_id if project_id.present?
      binds << name_bind if name_bind
      binds << environment if environment.present?
      binds.push(raw_lower, time_range.end)
      binds << project_id if project_id.present?
      binds << name_bind if name_bind
      binds << environment if environment.present?

      p50, p95, p99 = connection.select_rows(sanitize_sql_array([sql, *binds])).first || []
      {
        p50: p50 && Analytics::Histogram.index_to_ms(p50.to_i),
        p95: p95 && Analytics::Histogram.index_to_ms(p95.to_i),
        p99: p99 && Analytics::Histogram.index_to_ms(p99.to_i)
      }
    end

    def time_series_for_endpoint_global(time_range, project_id:, buckets:)
      rows = bucketed_volume(time_range: time_range, buckets: buckets, project_id: project_id)
      Array.new(buckets) do |b|
        r = rows[b]
        if r.nil? || r[:count].zero?
          {"bucket" => b, "count" => 0, "avg_duration" => 0}
        else
          {"bucket" => b, "count" => r[:count], "avg_duration" => (r[:sum].to_f / r[:count]).round(1)}
        end
      end
    end
  end
end
