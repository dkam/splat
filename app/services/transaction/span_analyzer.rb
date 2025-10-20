# frozen_string_literal: true

# Service class for analyzing transaction spans and extracting performance metrics
class Transaction
  class SpanAnalyzer
    # Extract timing data from spans when measurements are unavailable
    def self.extract_timing_data(spans = [])
      return { db_time: nil, view_time: nil } if spans.blank?

      db_time = calculate_total_time_for_operations(spans, "db.sql.active_record")
      view_time = calculate_total_time_for_operations(spans, "view.process_action.action_controller")

      {
        db_time: db_time&.round,
        view_time: view_time&.round
      }
    end

    # Analyze SQL queries for performance patterns and N+1 detection
    def self.analyze_sql_queries(breadcrumbs = [])
      return {
        total_queries: 0,
        unique_patterns: 0,
        potential_n_plus_one: [],
        query_patterns: {}
      } if breadcrumbs.blank?

      sql_breadcrumbs = breadcrumbs.select { |bc| bc["category"] == "sql.active_record" }

      return {
        total_queries: 0,
        unique_patterns: 0,
        potential_n_plus_one: [],
        query_patterns: {}
      } if sql_breadcrumbs.blank?

      # Extract and normalize SQL patterns
      query_patterns = {}
      sql_breadcrumbs.each do |breadcrumb|
        sql = breadcrumb.dig("data", "sql")
        next if sql.blank?

        # Normalize SQL by removing literal values and focusing on structure
        pattern = normalize_sql_pattern(sql)
        query_patterns[pattern] ||= { count: 0, examples: [] }
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

    private

    # Calculate total duration for specific operation types
    def self.calculate_total_time_for_operations(spans, operation_type)
      matching_spans = spans.select { |span| span["op"] == operation_type }
      return nil if matching_spans.empty?

      total_time = matching_spans.sum do |span|
        next 0 unless span["start_timestamp"] && span["timestamp"]

        duration_ms = (span["timestamp"] - span["start_timestamp"]) * 1000
        duration_ms.round
      end

      total_time > 0 ? total_time.round : nil
    end

    # Normalize SQL pattern by removing literal values
    def self.normalize_sql_pattern(sql)
      # Remove string literals (single and double quotes)
      pattern = sql.gsub(/'[^']*'/, "?").gsub(/"[^"]*"/, "?")

      # Remove numbers
      pattern = pattern.gsub(/\b\d+\b/, "?")

      # Remove IN lists with multiple values
      pattern = pattern.gsub(/\(IN\s*\([^)]+\)\)/i, "(IN (?))")

      # Normalize UUIDs
      pattern = pattern.gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "?")

      # Normalize IPs, emails, URLs
      pattern = pattern.gsub(/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, "?")
      pattern = pattern.gsub(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "?")
      pattern = pattern.gsub(/https?:\/\/[^\s]+/, "?")

      # Remove excessive whitespace
      pattern = pattern.gsub(/\s+/, " ").strip

      pattern
    end
  end
end