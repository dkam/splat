require "test_helper"

class StorageStatsTest < ActiveSupport::TestCase
  # The "Spans" count must reflect spans now stored inside span_trees blobs, not
  # just the frozen legacy `spans` table — otherwise it counts down to zero as
  # retention prunes old rows while real span volume keeps growing.
  test "counts spans as legacy rows plus the span_count packed in span_trees" do
    SpanTree.create_from_tree!(project_id: 1, transaction_id: "t1", timestamp: Time.current,
      tree: {"spans" => []}, span_count: 40, spans_truncated: false)
    SpanTree.create_from_tree!(project_id: 1, transaction_id: "t2", timestamp: Time.current,
      tree: {"spans" => []}, span_count: 15, spans_truncated: false)

    # Stand-in for the scanned groups: a legacy spans table with 100 rows.
    groups = [{name: "Transactions + Spans", tables: [{name: "spans", row_estimate: 100}]}]

    counts = StorageStats.counts(groups)

    assert_equal 100 + 55, counts[:spans], "legacy 100 rows + 40 + 15 span_count"
  end

  test "counts maps table row_estimates to the headline metrics" do
    groups = [
      {name: "Issues + Events", tables: [
        {name: "issues", row_estimate: 7}, {name: "events", row_estimate: 1234}
      ]},
      {name: "Transactions + Spans", tables: [
        {name: "transactions", row_estimate: 88}, {name: "spans", row_estimate: 0}
      ]},
      {name: "Logs", tables: [{name: "logs", row_estimate: 555}]}
    ]

    counts = StorageStats.counts(groups)

    assert_equal 7, counts[:issues]
    assert_equal 1234, counts[:events]
    assert_equal 88, counts[:transactions]
    assert_equal 555, counts[:logs]
    assert_equal 0, counts[:spans] # no span_trees seeded
  end
end
