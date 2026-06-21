# frozen_string_literal: true

# Service class for analyzing transaction spans and extracting performance metrics
class Transaction
  class SpanAnalyzer
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

    # Analyze SQL queries for performance patterns and N+1 detection
    def self.analyze_sql_queries(breadcrumbs = [])
      if breadcrumbs.blank?
        return {
          total_queries: 0,
          unique_patterns: 0,
          potential_n_plus_one: [],
          query_patterns: {}
        }
      end

      sql_breadcrumbs = breadcrumbs.select { |bc| bc["category"] == "sql.active_record" }

      if sql_breadcrumbs.blank?
        return {
          total_queries: 0,
          unique_patterns: 0,
          potential_n_plus_one: [],
          query_patterns: {}
        }
      end

      # Extract and normalize SQL patterns
      query_patterns = {}
      sql_breadcrumbs.each do |breadcrumb|
        sql = breadcrumb.dig("data", "sql")
        next if sql.blank?

        # Normalize SQL by removing literal values and focusing on structure
        pattern = normalize_sql_pattern(sql)
        query_patterns[pattern] ||= {count: 0, examples: []}
        query_patterns[pattern][:count] += 1
        query_patterns[pattern][:examples] << sql if query_patterns[pattern][:examples].size < 3
      end

      # Detect potential N+1 queries (same pattern executed multiple times)
      potential_n_plus_one = query_patterns.select { |pattern, data| data[:count] > 3 }.keys

      {
        total_queries: sql_breadcrumbs.size,
        unique_patterns: query_patterns.size,
        potential_n_plus_one: potential_n_plus_one,
        query_patterns: query_patterns
      }
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

    # /* ... */ query log tag comments carry per-request data (request_id,
    # source_location) — they'd fragment patterns into one-per-request and
    # break N+1 detection.
    BLOCK_COMMENT = SqlNormalizer::BLOCK_COMMENT

    # Single union covers everything we collapse to "?" — UUID first so it
    # doesn't get pre-eaten by the bare \d+ rule, then IN-lists, IPs, emails,
    # URLs, single-quoted strings, and finally bare numbers. Double-quoted
    # tokens are deliberately omitted — they're Postgres identifiers
    # (table/column names) and must survive so different tables yield
    # different patterns.
    VALUES = Regexp.union(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i,
      /\bIN\s*\([^)]+\)/i,
      /\b\d{1,3}(?:\.\d{1,3}){3}\b/,
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
      %r{https?://\S+},
      /'[^']*'/,
      /\b\d+\b/
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

    private_class_method :calculate_total_time_for_operations, :normalize_sql_pattern
  end
end
