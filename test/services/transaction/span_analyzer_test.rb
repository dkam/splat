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
end
