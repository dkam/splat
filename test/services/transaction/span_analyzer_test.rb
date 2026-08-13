# frozen_string_literal: true

require "test_helper"

class Transaction::SpanAnalyzerTest < ActiveSupport::TestCase
  def normalize(sql)
    Transaction::SpanAnalyzer.send(:normalize_sql_pattern, sql)
  end

  test "preserves double-quoted identifiers so different tables stay distinct" do
    users = normalize('SELECT "users".* FROM "users" WHERE "users"."id" = 42')
    products = normalize('SELECT "products".* FROM "products" WHERE "products"."id" = 42')
    refute_equal users, products
    assert_includes users, '"users"'
    assert_includes products, '"products"'
  end

  test "strips /* ... */ query log tag comments so request_id does not fragment patterns" do
    a = normalize("SELECT 1 /*request_id='abc-123'*/")
    b = normalize("SELECT 1 /*request_id='def-456'*/")
    assert_equal a, b
    refute_includes a, "request_id"
  end

  test "two lookups with same shape but different values collapse to one pattern" do
    one = normalize('SELECT "users".* FROM "users" WHERE "users"."id" = 1 LIMIT 1')
    two = normalize('SELECT "users".* FROM "users" WHERE "users"."id" = 999 LIMIT 1')
    assert_equal one, two
  end

  test "single-quoted literals become ?" do
    out = normalize("INSERT INTO users (email) VALUES ('alice@example.com')")
    assert_includes out, "(?)"
    refute_includes out, "alice"
  end

  test "analyze_sql_queries flags repeated pattern as N+1" do
    breadcrumbs = 5.times.map do |i|
      {
        "category" => "sql.active_record",
        "data" => {"sql" => %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1)}
      }
    end

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    assert_equal 5, result[:total_queries]
    assert_equal 1, result[:unique_patterns]
    assert_equal 1, result[:potential_n_plus_one].size
  end

  test "stores at most one example per pattern" do
    breadcrumbs = 5.times.map do |i|
      {
        "category" => "sql.active_record",
        "data" => {"sql" => %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1)}
      }
    end

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    result[:query_patterns].each_value do |data|
      assert_equal 1, data[:examples].size
    end
    # The example is a real query with its literal values intact.
    assert_includes result[:query_patterns].values.first[:examples].first, "= 0"
  end

  test "caps stored SQL length for both pattern keys and examples" do
    max = Transaction::SpanAnalyzer::MAX_SQL_LENGTH
    # A wide column list survives normalization (identifiers are kept), so
    # both the pattern and the example blow past the cap.
    columns = 200.times.map { |i| %("books"."column_#{i}") }.join(", ")
    breadcrumbs = 2.times.map do |i|
      {"category" => "sql.active_record",
       "data" => {"sql" => %(SELECT #{columns} FROM "books" WHERE "books"."id" = #{i})}}
    end

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)

    # Both rows still collapse into one pattern despite truncation.
    assert_equal 1, result[:query_patterns].size
    pattern, data = result[:query_patterns].first
    assert_equal max + 1, pattern.length # cap plus the "…" marker
    assert pattern.end_with?("…")
    assert_equal max + 1, data[:examples].first.length
    assert data[:examples].first.end_with?("…")

    # Short queries are stored untouched.
    short = Transaction::SpanAnalyzer.analyze_sql_queries(
      [{"category" => "sql.active_record", "data" => {"sql" => "SELECT 1 FROM books"}}]
    )
    refute short[:query_patterns].keys.first.end_with?("…")
  end

  test "collapses IN-lists regardless of arity" do
    a = normalize("SELECT 1 FROM users WHERE id IN (1, 2, 3)")
    b = normalize("SELECT 1 FROM users WHERE id IN (1, 2, 3, 4, 5, 6)")
    assert_equal a, b
    assert_includes a, "IN (?)"
  end

  test "collapses UUIDs, IPs, emails, URLs to ?" do
    out = normalize(
      "SELECT 1 FROM logs WHERE uuid = '11111111-2222-3333-4444-555555555555' " \
      "AND ip = '127.0.0.1' AND email = 'a@b.co' AND url = 'https://x.test/y'"
    )
    refute_match(/11111111|127\.0\.0\.1|a@b\.co|https:/, out)
  end

  test "different tables with same shape do not collapse into one pattern" do
    breadcrumbs = [
      {"category" => "sql.active_record", "data" => {"sql" => 'SELECT "regions".* FROM "regions" WHERE "regions"."id" = 1'}},
      {"category" => "sql.active_record", "data" => {"sql" => 'SELECT "regions".* FROM "regions" WHERE "regions"."id" = 2'}},
      {"category" => "sql.active_record", "data" => {"sql" => 'SELECT "languages".* FROM "languages" WHERE "languages"."id" = 1'}},
      {"category" => "sql.active_record", "data" => {"sql" => 'SELECT "products".* FROM "products" WHERE "products"."id" = 1'}}
    ]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    assert_equal 4, result[:total_queries]
    assert_equal 3, result[:unique_patterns]
  end

  # Infrastructure queries (SolidCache/Queue/Cable, schema bookkeeping, SQLite
  # introspection) are framework plumbing, not application N+1s. They share a
  # tiny set of shapes and would otherwise trip the repeated-pattern heuristic.
  test "SolidCache traffic alone is not flagged as N+1 and does not count as queries" do
    breadcrumbs = [
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT "solid_cache_entries"."key", "solid_cache_entries"."value" FROM "solid_cache_entries" WHERE "solid_cache_entries"."key_hash" IN (1))}},
      {"category" => "sql.active_record", "data" => {"sql" => %(DELETE FROM "solid_cache_entries" WHERE "solid_cache_entries"."key_hash" = 2)}},
      {"category" => "sql.active_record", "data" => {"sql" => %(INSERT INTO "solid_cache_entries" ("key","value") VALUES ('a', 'b'))}},
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT "solid_cache_entries"."key" FROM "solid_cache_entries" WHERE "solid_cache_entries"."key_hash" IN (3))}}
    ]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    assert_equal 0, result[:total_queries]
    assert_empty result[:potential_n_plus_one]
  end

  test "infrastructure queries are excluded but a real app N+1 alongside them still flags" do
    app = 5.times.map do |i|
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT "issues".* FROM "issues" WHERE "issues"."id" = #{i} LIMIT 1)}}
    end
    infra = [
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT "solid_cache_entries"."value" FROM "solid_cache_entries" WHERE "solid_cache_entries"."key_hash" IN (9))}},
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT "solid_queue_ready_executions".* FROM "solid_queue_ready_executions" LIMIT 1)}},
      {"category" => "sql.active_record", "data" => {"sql" => "SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name"}},
      {"category" => "sql.active_record", "data" => {"sql" => %(SELECT COUNT(*) FROM "schema_migrations")}}
    ]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(app + infra)
    # Only the 5 issue lookups count; infra is dropped.
    assert_equal 5, result[:total_queries]
    assert_equal 1, result[:unique_patterns]
    assert_equal 1, result[:potential_n_plus_one].size
  end

  test "infrastructure_query? matches plumbing tables across quoting styles" do
    assert Transaction::SpanAnalyzer.infrastructure_query?(%(SELECT * FROM "solid_cache_entries"))
    assert Transaction::SpanAnalyzer.infrastructure_query?("SELECT * FROM solid_queue_jobs")
    assert Transaction::SpanAnalyzer.infrastructure_query?("SELECT name FROM dbstat")
    refute Transaction::SpanAnalyzer.infrastructure_query?(%(SELECT * FROM "products"))
    refute Transaction::SpanAnalyzer.infrastructure_query?(nil)
  end

  test "infrastructure_query? matches Postgres catalog introspection" do
    # The shapes Rails' PG adapter actually fires on connection/boot.
    assert Transaction::SpanAnalyzer.infrastructure_query?(
      "SELECT a.attnum, a.attname FROM pg_attribute a WHERE a.attrelid = 1234"
    )
    assert Transaction::SpanAnalyzer.infrastructure_query?(
      "SELECT pg_get_indexdef(indexrelid) FROM pg_index"
    )
    assert Transaction::SpanAnalyzer.infrastructure_query?(
      "SELECT pg_catalog.obj_description(1234, 'pg_class')"
    )
    assert Transaction::SpanAnalyzer.infrastructure_query?(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
    )
    assert Transaction::SpanAnalyzer.infrastructure_query?(
      "SELECT t.oid, t.typname FROM pg_type t WHERE t.typtype = 'e'"
    )
  end

  test "application tables with a pg_ prefix are NOT infrastructure" do
    # pg_search gem's table — a blanket /pg_\w+/ would swallow it.
    refute Transaction::SpanAnalyzer.infrastructure_query?(
      %(SELECT "pg_search_documents".* FROM "pg_search_documents" WHERE "pg_search_documents"."searchable_id" = 5)
    )
  end

  test "boolean literals collapse so TRUE and FALSE variants share a pattern" do
    a = normalize('SELECT "users".* FROM "users" WHERE "users"."active" = TRUE')
    b = normalize('SELECT "users".* FROM "users" WHERE "users"."active" = FALSE')
    c = normalize('SELECT "users".* FROM "users" WHERE "users"."active" = false')
    assert_equal a, b
    assert_equal a, c
    refute_match(/TRUE|FALSE/i, a)
  end

  test "floats, negatives, and scientific notation collapse like integers" do
    a = normalize('SELECT 1 FROM "prices" WHERE "prices"."amount" > 19.99')
    b = normalize('SELECT 1 FROM "prices" WHERE "prices"."amount" > 24.50')
    assert_equal a, b

    c = normalize('SELECT 1 FROM "prices" WHERE "prices"."delta" = -5')
    d = normalize('SELECT 1 FROM "prices" WHERE "prices"."delta" = -12')
    assert_equal c, d

    e = normalize('SELECT 1 FROM "prices" WHERE "prices"."tiny" < 1.5e10')
    f = normalize('SELECT 1 FROM "prices" WHERE "prices"."tiny" < 2.5e12')
    assert_equal e, f
  end

  test "numeric collapse leaves identifiers containing digits alone" do
    out = normalize('SELECT "books"."column_2" FROM "books" WHERE "books"."id" = 7')
    assert_includes out, '"column_2"'
    assert_includes out, "= ?"
  end

  test "distinct_count separates N+1 over N records from the identical query repeated" do
    n_plus_one = 5.times.map do |i|
      {"category" => "sql.active_record",
       "data" => {"sql" => %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1)}}
    end
    repeated = 5.times.map do
      {"category" => "sql.active_record",
       "data" => {"sql" => %(SELECT "settings".* FROM "settings" WHERE "settings"."key" = 'theme' LIMIT 1)}}
    end

    result = Transaction::SpanAnalyzer.analyze_sql_queries(n_plus_one + repeated)
    assert_equal 2, result[:unique_patterns]

    by_distinct = result[:query_patterns].values.sort_by { |d| d[:distinct_count] }
    assert_equal 1, by_distinct.first[:distinct_count]   # settings: byte-identical ×5
    assert_equal 5, by_distinct.first[:count]
    assert_equal 5, by_distinct.last[:distinct_count]    # users: 5 different ids
    assert_equal 5, by_distinct.last[:count]

    # The transient raw-SQL set never reaches the stored structure.
    result[:query_patterns].each_value { |d| refute d.key?(:raw_seen) }
  end

  # ---- Duration weighting: db spans contribute timing to patterns. ----

  def db_breadcrumb(sql)
    {"category" => "sql.active_record", "data" => {"sql" => sql}}
  end

  def db_span(sql, duration_ms:, op: "db.sql.active_record", at: 1_700_000_000.0)
    {"op" => op, "description" => sql, "start_timestamp" => at, "timestamp" => at + (duration_ms / 1000.0)}
  end

  test "span durations are summed into the pattern they normalize to" do
    sqls = 5.times.map { |i| %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1) }
    breadcrumbs = sqls.map { |s| db_breadcrumb(s) }
    spans = sqls.map { |s| db_span(s, duration_ms: 8) }

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs, spans: spans)
    data = result[:query_patterns].values.first
    assert_in_delta 40.0, data[:total_time_ms], 0.5
    # All the wasted time sits in the one flagged pattern.
    assert_in_delta 40, result[:n_plus_one_time_ms], 1
  end

  test "n_plus_one_time_ms sums only flagged patterns, not one-off queries" do
    n_plus_one = 5.times.map { |i| %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1) }
    one_off = %(SELECT "posts".* FROM "posts" WHERE "posts"."id" = 1)
    breadcrumbs = (n_plus_one + [one_off]).map { |s| db_breadcrumb(s) }
    spans = n_plus_one.map { |s| db_span(s, duration_ms: 10) } + [db_span(one_off, duration_ms: 500)]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs, spans: spans)
    # The slow one-off keeps its own timing but never counts as waste.
    assert_in_delta 50, result[:n_plus_one_time_ms], 1
    one_off_pattern = result[:query_patterns].find { |k, _| k.include?("posts") }.last
    assert_in_delta 500.0, one_off_pattern[:total_time_ms], 0.5
  end

  test "without spans, timing fields stay absent and n_plus_one_time_ms is nil" do
    breadcrumbs = 5.times.map { |i| db_breadcrumb(%(SELECT "users".* FROM "users" WHERE "users"."id" = #{i})) }

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    assert_nil result[:n_plus_one_time_ms]
    result[:query_patterns].each_value { |d| refute d.key?(:total_time_ms) }
    # Unknown ≠ zero: the flag itself is unaffected.
    assert_equal 1, result[:potential_n_plus_one].size
  end

  test "non-db spans and spans matching no pattern contribute nothing" do
    sqls = 5.times.map { |i| %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i}) }
    breadcrumbs = sqls.map { |s| db_breadcrumb(s) }
    spans = [
      db_span(sqls.first, duration_ms: 100, op: "view.process_action.action_controller"),
      db_span(%(SELECT "unrelated".* FROM "unrelated"), duration_ms: 100),
      db_span(sqls.first, duration_ms: 7)
    ]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs, spans: spans)
    assert_in_delta 7, result[:n_plus_one_time_ms], 1
  end
end
