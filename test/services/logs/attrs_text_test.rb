require "test_helper"

class Logs::AttrsTextTest < ActiveSupport::TestCase
  test "flattens key/value pairs to a space-joined string" do
    txt = Logs::AttrsText.build({"controller" => "ProjectsController", "action" => "show"})
    assert_equal "controller ProjectsController action show", txt
  end

  test "unwraps Sentry {value} and OTLP AnyValue shapes" do
    txt = Logs::AttrsText.build({
      "env" => {"value" => "production"},
      "db.system" => {"stringValue" => "postgresql"}
    })
    assert_includes txt, "env production"
    assert_includes txt, "db.system postgresql"
  end

  test "drops floating-point values (timings) but keeps the key" do
    txt = Logs::AttrsText.build({
      "status" => "422",
      "duration_ms" => "317.42",
      "view_runtime_ms" => "0.09"
    })
    assert_includes txt, "status 422", "low-cardinality integer kept"
    assert_includes txt, "duration_ms", "key still emitted"
    refute_includes txt, "317.42", "float value dropped from the index"
    refute_includes txt, "0.09"
  end

  test "caps long values so a bulk SQL statement can't flood the index" do
    stmt = "INSERT INTO cold_series (id, value) VALUES " + (1..20_000).map { |i| "(#{i}, #{i * 7})" }.join(", ")
    txt = Logs::AttrsText.build({"db.statement" => stmt, "db.system" => "postgresql"})

    assert_includes txt, "db.statement INSERT INTO cold_series", "head of the value still searchable"
    assert_includes txt, "db.system postgresql", "later attributes unaffected"
    refute_includes txt, "(20000,", "tail dropped"
    assert_operator txt.length, :<, Logs::AttrsText::MAX_VALUE_CHARS + 100
  end

  test "drops the word fragment a cut lands in" do
    max = Logs::AttrsText::MAX_VALUE_CHARS
    value = ("a" * (max - 3)) + " splitword"
    txt = Logs::AttrsText.build({"k" => value})

    assert_equal "k #{"a" * (max - 3)} ", txt, "partial 'spl' not indexed"
  end

  test "leaves values at the cap untouched" do
    value = "x" * Logs::AttrsText::MAX_VALUE_CHARS
    assert_equal "k #{value}", Logs::AttrsText.build({"k" => value})
  end

  test "collapses a UUID before capping so the cut can't split it" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    value = ("a " * ((Logs::AttrsText::MAX_VALUE_CHARS - 34) / 2)) + uuid
    txt = Logs::AttrsText.build({"k" => value})

    assert_includes txt, "550e8400e29b41d4a716446655440000"
  end

  test "returns nil for blank input" do
    assert_nil Logs::AttrsText.build({})
    assert_nil Logs::AttrsText.build(nil)
  end
end
