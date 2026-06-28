require "test_helper"

class SpanTreeTest < ActiveSupport::TestCase
  setup { @project = projects(:one) }

  test "create_from_tree! round-trips the tree through plain zstd (no dict tables)" do
    tree = {"trace_id" => "tr-1", "spans" => [
      {"span_id" => "s1", "parent_span_id" => nil, "op" => "http.server", "status" => "ok",
       "description" => "GET /", "ts" => "2026-06-25T10:00:00.000Z", "end_ts" => "2026-06-25T10:00:00.120Z",
       "depth" => 0, "sequence" => 0, "tags" => {}, "data" => {}}
    ]}

    st = SpanTree.create_from_tree!(
      project_id: @project.id, transaction_id: "txn-st", timestamp: Time.current,
      tree: tree, span_count: 1, spans_truncated: false
    )

    assert_nil st.dict_id, "v1 stores plain zstd (no dictionary)"
    assert st.payload_blob.bytesize.positive?
    assert_equal tree, SpanTree.find(st.id).tree, "blob decodes back to the exact tree"
  end
end
