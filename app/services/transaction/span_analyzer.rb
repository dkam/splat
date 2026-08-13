# frozen_string_literal: true

# Service class for analyzing transaction spans and extracting performance metrics
class Transaction
  class SpanAnalyzer
    # A pattern repeated more than this many times in one request is flagged as
    # a potential N+1. Shared with Transaction#potential_n_plus_one_queries,
    # which re-derives the flag from stored per-pattern counts at read time.
    N_PLUS_ONE_THRESHOLD = 3

    # Stored SQL (pattern keys and examples) is capped at this many characters.
    # Nothing else bounds it — a multi-row INSERT or wide SELECT arriving as a
    # breadcrumb can be tens of KB and would land in the JSON twice (normalized
    # key + raw example). Sentry truncates around 1 KB for the same reason.
    MAX_SQL_LENGTH = 1000

    # Extract timing data from spans when measurements are unavailable
    def self.extract_timing_data(spans = [])
      return {db_time: nil, view_time: nil} if spans.blank?

      db_time = calculate_total_time_for_operations(spans, "db.sql.active_record")
      view_time = calculate_total_time_for_operations(spans, "view.process_action.action_controller")

      {
        db_time: db_time&.round,
        view_time: view_time&.round
      }
    end

    # Analyze SQL queries for performance patterns and N+1 detection.
    # Breadcrumbs are the source of truth for counts (every query leaves one);
    # spans, when given, contribute timing — each db span's duration is
    # attributed to the pattern its description normalizes to, so findings can
    # be ranked by wasted time rather than repetition count.
    def self.analyze_sql_queries(breadcrumbs = [], spans: [])
      empty = {
        total_queries: 0,
        unique_patterns: 0,
        potential_n_plus_one: [],
        query_patterns: {},
        n_plus_one_time_ms: nil
      }
      return empty if breadcrumbs.blank?

      sql_breadcrumbs = breadcrumbs
        .select { |bc| bc["category"] == "sql.active_record" }
        .reject { |bc| infrastructure_query?(bc.dig("data", "sql")) }

      return empty if sql_breadcrumbs.blank?

      # Extract and normalize SQL patterns
      query_patterns = {}
      sql_breadcrumbs.each do |breadcrumb|
        sql = breadcrumb.dig("data", "sql")
        next if sql.blank?

        # Normalize SQL by removing literal values and focusing on structure.
        # Truncate AFTER normalizing — normalization already collapses the
        # usual size offenders (IN-lists, literals), and truncating first
        # would cut queries at arbitrary points and fragment patterns.
        pattern = truncate_sql(normalize_sql_pattern(sql))
        query_patterns[pattern] ||= {count: 0, examples: [], raw_seen: Set.new}
        query_patterns[pattern][:count] += 1
        query_patterns[pattern][:raw_seen] << sql
        # One example (with real literal values) is all the UI ever renders;
        # extra copies of full SQL strings were the transactions table's
        # biggest storage cost.
        query_patterns[pattern][:examples] << truncate_sql(sql) if query_patterns[pattern][:examples].empty?
      end

      # distinct_count separates the two failure modes a repeated pattern can
      # mean: count high + distinct high → N+1 over N records (fix: eager
      # loading); count high + distinct 1 → the byte-identical query fired
      # N times (fix: memoisation / query cache). Only the integer is stored.
      query_patterns.each_value do |data|
        data[:distinct_count] = data.delete(:raw_seen).size
      end

      attribute_span_durations(query_patterns, spans)

      # Detect potential N+1 queries (same pattern executed multiple times)
      potential_n_plus_one = query_patterns.select { |pattern, data| data[:count] > N_PLUS_ONE_THRESHOLD }.keys

      {
        total_queries: sql_breadcrumbs.size,
        unique_patterns: query_patterns.size,
        potential_n_plus_one: potential_n_plus_one,
        query_patterns: query_patterns,
        n_plus_one_time_ms: n_plus_one_time_ms(query_patterns, potential_n_plus_one)
      }
    end

    # Sum each db span's duration into the pattern its description normalizes
    # to. Spans and breadcrumbs both originate from sql.active_record
    # notifications, so the raw SQL text matches; patterns with no matching
    # span (span cap hit, spans absent) simply get no total_time_ms — timing
    # is additive information, never a substitute for the breadcrumb counts.
    def self.attribute_span_durations(query_patterns, spans)
      return if spans.blank?

      spans.each do |span|
        next unless span["op"].to_s.start_with?("db")
        description = span["description"]
        next if description.blank? || !span["start_timestamp"] || !span["timestamp"]

        pattern = truncate_sql(normalize_sql_pattern(description))
        data = query_patterns[pattern]
        next unless data

        data[:total_time_ms] = (data[:total_time_ms] || 0.0) + ((span["timestamp"] - span["start_timestamp"]) * 1000)
      end

      query_patterns.each_value do |data|
        data[:total_time_ms] = data[:total_time_ms].round(1) if data[:total_time_ms]
      end
    end

    # The transaction's wasted-time scalar: summed db time of its flagged
    # patterns. nil (not 0) when no flagged pattern got span timing — unknown
    # and zero must stay distinguishable in the hourly aggregates.
    def self.n_plus_one_time_ms(query_patterns, potential_n_plus_one)
      timed = potential_n_plus_one.filter_map { |p| query_patterns.dig(p, :total_time_ms) }
      return nil if timed.empty?
      timed.sum.round
    end

    # Calculate total duration for specific operation types
    def self.calculate_total_time_for_operations(spans, operation_type)
      matching_spans = spans.select { |span| span["op"] == operation_type }
      return nil if matching_spans.empty?

      total_time = matching_spans.sum do |span|
        next 0 unless span["start_timestamp"] && span["timestamp"]

        duration_ms = (span["timestamp"] - span["start_timestamp"]) * 1000
        duration_ms.round
      end

      (total_time > 0) ? total_time.round : nil
    end

    # Queries against framework/infrastructure tables — cache, job queue,
    # cable, schema bookkeeping, SQLite introspection — are not application
    # N+1s. They share a tiny set of SQL shapes (SolidCache alone fires
    # get + delete + put on every Rails.cache.fetch miss), so a request doing
    # a handful of cache lookups trips the repeated-pattern heuristic even
    # though the app issued no redundant DB work. Excluding them up front means
    # both total_queries and the N+1 scan reflect application queries only.
    # Prosopite (charkost/prosopite) gets the same effect from call-site
    # grouping; we only have the SQL text, so we filter by table name. Matched
    # against raw SQL so quoting (PG "ident", SQLite/MySQL bareword/backtick)
    # doesn't matter — \b sits on the quote/word boundary either way.
    #
    # The Postgres entries name the catalog surface Rails introspection
    # actually touches (pg_catalog-qualified refs, specific pg_* relations,
    # pg_get_* functions) rather than a blanket pg_\w+ — application tables
    # like pg_search_documents must keep counting as app queries.
    INFRA_TABLE = Regexp.union(
      /\bsolid_cache_entries\b/i,
      /\bsolid_queue_\w+/i,
      /\bsolid_cable_messages\b/i,
      /\bschema_migrations\b/i,
      /\bar_internal_metadata\b/i,
      /\bsqlite_(?:master|sequence|stat\d*)\b/i,
      /\bdbstat\b/i,
      /\bpg_catalog\b/i,
      /\binformation_schema\b/i,
      /\bpg_(?:attribute|attrdef|class|index(?:es)?|type|namespace|constraint|depend|enum|range|proc|am|opclass|collation|description|database|settings|sequences?|tables|matviews|get_\w+)\b/i
    ).freeze

    def self.infrastructure_query?(sql)
      sql.present? && INFRA_TABLE.match?(sql)
    end

    def self.truncate_sql(sql)
      (sql.length > MAX_SQL_LENGTH) ? "#{sql[0, MAX_SQL_LENGTH]}…" : sql
    end

    # /* ... */ query log tag comments carry per-request data (request_id,
    # source_location) — they'd fragment patterns into one-per-request and
    # break N+1 detection.
    BLOCK_COMMENT = SqlNormalizer::BLOCK_COMMENT

    # Single union covers everything we collapse to "?" — UUID first so it
    # doesn't get pre-eaten by the numeric rule, then IN-lists, IPs, emails,
    # URLs, single-quoted strings, booleans, and finally bare numbers
    # (SqlNormalizer's literal rule, so floats/negatives/scientific notation
    # group the same way in both normalizers). Booleans collapse because
    # `active = TRUE` and `active = FALSE` are the same query shape — split
    # patterns halve counts and hide detections. Double-quoted tokens are
    # deliberately omitted — they're Postgres identifiers (table/column
    # names) and must survive so different tables yield different patterns.
    VALUES = Regexp.union(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i,
      /\bIN\s*\([^)]+\)/i,
      /\b\d{1,3}(?:\.\d{1,3}){3}\b/,
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
      %r{https?://\S+},
      /'[^']*'/,
      /\b(?:TRUE|FALSE)\b/i,
      SqlNormalizer::NUMERIC_LITERAL
    )

    # Normalize SQL into a pattern key for grouping (N+1 detection).
    # Strips values, keeps identifiers. Two queries against the same table
    # with different ids map to the same pattern; queries against different
    # tables do not.
    def self.normalize_sql_pattern(sql)
      sql.gsub(BLOCK_COMMENT, "")
        .gsub(VALUES) { |m| m.match?(/\AIN/i) ? "IN (?)" : "?" }
        .gsub(SqlNormalizer::WHITESPACE, " ")
        .strip
    end

    private_class_method :calculate_total_time_for_operations, :normalize_sql_pattern, :truncate_sql,
      :attribute_span_durations, :n_plus_one_time_ms
  end
end
