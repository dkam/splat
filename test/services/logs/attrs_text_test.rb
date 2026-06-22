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

  test "returns nil for blank input" do
    assert_nil Logs::AttrsText.build({})
    assert_nil Logs::AttrsText.build(nil)
  end
end
