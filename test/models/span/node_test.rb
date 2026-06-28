require "test_helper"

class Span::NodeTest < ActiveSupport::TestCase
  def raw_span(overrides = {})
    {
      "span_id" => "s1", "parent_span_id" => "root", "op" => "db.sql.active_record",
      "status" => "ok", "description" => "SELECT ?",
      "ts" => "2026-06-25T10:00:00.000Z", "end_ts" => "2026-06-25T10:00:00.050Z",
      "depth" => 2, "sequence" => 5, "tags" => {"k" => "v"}, "data" => {"rows" => 1}
    }.merge(overrides)
  end

  test "exposes readers, computed duration_ms, and parsed Time" do
    n = Span::Node.new(raw_span, trace_id: "tr")
    assert_equal "db.sql.active_record", n.op
    assert_equal "SELECT ?", n.description
    assert_equal 2, n.depth
    assert_equal 5, n.sequence
    assert_equal "tr", n.trace_id
    assert_equal({"k" => "v"}, n.tags)
    assert_respond_to n.timestamp, :to_time
    assert_equal 50, n.duration_ms
  end

  test "string-key [] access matches the waterfall + MCP formatter" do
    n = Span::Node.new(raw_span, trace_id: "tr")
    assert_equal "db.sql.active_record", n["op"]
    assert_equal 2, n["depth"]
    assert_equal 50, n["duration_ms"]
    assert_equal "tr", n["trace_id"]
    assert_respond_to n["timestamp"], :to_time
  end

  test "attributes returns string keys for the MCP handler" do
    attrs = Span::Node.new(raw_span, trace_id: "tr").attributes
    assert_equal "SELECT ?", attrs["description"]
    assert_equal 2, attrs["depth"]
    assert_equal "tr", attrs["trace_id"]
  end

  test "from_tree sorts by sequence and hoists trace_id" do
    tree = {"trace_id" => "tr", "spans" => [
      raw_span("span_id" => "b", "sequence" => 2),
      raw_span("span_id" => "a", "sequence" => 1)
    ]}
    nodes = Span::Node.from_tree(tree)
    assert_equal %w[a b], nodes.map(&:span_id)
    assert nodes.all? { |n| n.trace_id == "tr" }
  end

  test "from_tree and from_record yield equivalent nodes" do
    from_tree = Span::Node.from_tree("trace_id" => "tr", "spans" => [raw_span]).first

    legacy = Span.new(
      span_id: "s1", parent_span_id: "root", op: "db.sql.active_record", status: "ok",
      description: "SELECT ?", trace_id: "tr",
      timestamp: Time.parse("2026-06-25T10:00:00.000Z"),
      end_timestamp: Time.parse("2026-06-25T10:00:00.050Z"),
      depth: 2, sequence: 5, tags: {"k" => "v"}, data: {"rows" => 1}
    )
    from_record = Span::Node.from_record(legacy)

    assert_equal from_tree.attributes.except("timestamp", "end_timestamp"),
      from_record.attributes.except("timestamp", "end_timestamp")
    assert_equal from_tree.duration_ms, from_record.duration_ms
    assert_equal from_tree.timestamp.to_i, from_record.timestamp.to_i
  end
end
