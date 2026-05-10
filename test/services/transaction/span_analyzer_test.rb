# frozen_string_literal: true

require "test_helper"

class Transaction::SpanAnalyzerTest < ActiveSupport::TestCase
  def normalize(sql)
    Transaction::SpanAnalyzer.send(:normalize_sql_pattern, sql)
  end

  test "preserves double-quoted identifiers so different tables stay distinct" do
    users    = normalize('SELECT "users".* FROM "users" WHERE "users"."id" = 42')
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
        "data" => { "sql" => %(SELECT "users".* FROM "users" WHERE "users"."id" = #{i} LIMIT 1) }
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
      { "category" => "sql.active_record", "data" => { "sql" => 'SELECT "regions".* FROM "regions" WHERE "regions"."id" = 1' } },
      { "category" => "sql.active_record", "data" => { "sql" => 'SELECT "regions".* FROM "regions" WHERE "regions"."id" = 2' } },
      { "category" => "sql.active_record", "data" => { "sql" => 'SELECT "languages".* FROM "languages" WHERE "languages"."id" = 1' } },
      { "category" => "sql.active_record", "data" => { "sql" => 'SELECT "products".* FROM "products" WHERE "products"."id" = 1' } }
    ]

    result = Transaction::SpanAnalyzer.analyze_sql_queries(breadcrumbs)
    assert_equal 4, result[:total_queries]
    assert_equal 3, result[:unique_patterns]
  end
end
