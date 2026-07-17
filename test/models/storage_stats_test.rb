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

  # The sampler replaced `ORDER BY RANDOM() LIMIT n`, which scanned and sorted
  # the whole table. Anchored rowid runs must still produce a usable estimate.
  test "compression_estimate samples blobs and scales by the table's row count" do
    30.times do |i|
      SpanTree.create_from_tree!(project_id: 1, transaction_id: "t#{i}", timestamp: Time.current,
        tree: {"spans" => [{"op" => "db.sql.query", "description" => "SELECT * FROM books" * 20}]},
        span_count: 3, spans_truncated: false)
    end

    estimate = StorageStats.compression_estimate({"span_trees" => 30}).find { |e| e[:name] == "Spans" }

    assert estimate, "expected a Spans compression estimate"
    assert estimate[:sample].positive?, "expected blobs to be decoded"
    assert estimate[:ratio] > 1, "repetitive payloads should compress"
    assert_equal 30, estimate[:rows], "all 30 rows carry a payload_blob"
    assert estimate[:saved_bytes].positive?
  end

  # A table the deep pass hasn't counted yet can't be scaled into a total, and
  # counting it inline would reintroduce the full scan we just removed.
  test "compression_estimate skips tables with no known row count" do
    SpanTree.create_from_tree!(project_id: 1, transaction_id: "t1", timestamp: Time.current,
      tree: {"spans" => []}, span_count: 1, spans_truncated: false)

    assert_empty StorageStats.compression_estimate({})
  end

  # refresh! is the hourly pass and deliberately does not rebuild `groups` —
  # that needs the dbstat walk. It must carry the deep pass's results forward
  # rather than blanking the per-table breakdown every hour.
  test "refresh! carries groups and counts forward from the last deep pass" do
    deep = StorageStats.refresh_deep!
    assert deep[:groups].any?, "deep pass should build the per-table breakdown"
    assert_equal deep[:collected_at], deep[:deep_collected_at]

    fast = StorageStats.refresh!

    assert_equal deep[:groups], fast[:groups]
    assert_equal deep[:counts], fast[:counts]
    assert_equal deep[:deep_collected_at], fast[:deep_collected_at],
      "deep_collected_at should keep pointing at the deep pass, not the fast one"
    assert fast[:collected_at] >= deep[:collected_at]
  end

  test "file_bytes_total reports on-disk bytes across every DB" do
    assert StorageStats.file_bytes_total.positive?
  end
end
