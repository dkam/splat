# frozen_string_literal: true

require "test_helper"

class Transaction::SqlNormalizerTest < ActiveSupport::TestCase
  def normalize(s)
    Transaction::SqlNormalizer.normalize(s)
  end

  test "passes through nil" do
    assert_nil normalize(nil)
  end

  test "strips numeric literals" do
    assert_equal "SELECT * FROM users WHERE id = ?",
      normalize("SELECT * FROM users WHERE id = 42")
  end

  test "strips string literals (single-quoted)" do
    assert_equal "INSERT INTO users (email) VALUES (?)",
      normalize("INSERT INTO users (email) VALUES ('alice@example.com')")
  end

  test "leaves double-quoted identifiers alone (Postgres style)" do
    out = normalize('SELECT "users".* FROM "users" WHERE "users"."id" = 42')
    assert_includes out, '"users"'
    assert_includes out, "= ?"
  end

  test "collapses IN-list to IN (?)" do
    assert_equal "SELECT * FROM users WHERE id IN (?)",
      normalize("SELECT * FROM users WHERE id IN (1, 2, 3, 4, 5)")
  end

  test "collapses whitespace" do
    assert_equal "SELECT * FROM users",
      normalize("SELECT *\n\n  FROM\tusers")
  end

  test "does not strip digits embedded in identifiers" do
    out = normalize("SELECT col1 FROM table9")
    assert_equal "SELECT col1 FROM table9", out
  end

  test "truncates to MAX_LEN" do
    long = "SELECT " + ("x" * 5000)
    assert_equal Transaction::SqlNormalizer::MAX_LEN, normalize(long).bytesize
  end
end
