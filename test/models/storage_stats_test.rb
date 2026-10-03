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
        {name: "transactions", row_estimate: 88}, {name: "spans", row_estimate: 0},
        {name: "transaction_histograms", row_estimate: 4096}
      ]},
      {name: "Logs", tables: [{name: "logs", row_estimate: 555}]}
    ]

    counts = StorageStats.counts(groups)

    assert_equal 7, counts[:issues]
    assert_equal 1234, counts[:events]
    assert_equal 88, counts[:transactions]
    assert_equal 555, counts[:logs]
    assert_equal 0, counts[:spans] # no span_trees seeded
    # Read off the deep pass's table walk, not a live COUNT(*) on the request path.
    assert_equal 4096, counts[:histogram_rows]
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

  # A cold cache (SNAPSHOT_SCHEMA bump, or a fresh SolidCache) has no deep pass to
  # carry forward, and the hourly job usually fires before anyone loads the
  # settings page. If refresh! wrote its carried-forward defaults on a cold cache
  # it would leave an empty snapshot AND suppress SettingsController's deep
  # enqueue, which only fires when the snapshot is nil.
  test "refresh! builds a deep snapshot rather than caching an empty one on a cold cache" do
    Rails.cache.delete(StorageStats::CACHE_KEY)

    snap = StorageStats.refresh!

    assert snap[:groups].any?, "cold refresh! must build groups, not carry forward []"
    assert snap[:deep_collected_at], "cold refresh! must count as a deep pass"
    assert_equal snap[:collected_at], snap[:deep_collected_at]
  end

  # Same trap one step later: a snapshot that exists but has never had a deep
  # pass (e.g. written by an older build) must not be treated as carry-forwardable.
  test "refresh! rebuilds deep when a prior snapshot has no deep pass" do
    Rails.cache.write(StorageStats::CACHE_KEY, {groups: [], counts: {}, collected_at: Time.current})

    snap = StorageStats.refresh!

    assert snap[:groups].any?
    assert snap[:deep_collected_at]
  end

  test "file_bytes_total reports on-disk bytes across every DB" do
    assert StorageStats.file_bytes_total.positive?
  end

  test "daily_usage divides each retention setting's table bytes and rows by its days of data" do
    snap = {
      groups: [
        {name: "Issues + Events", tables: [{name: "events", row_estimate: 3000, total_bytes: 30_000_000}]},
        {name: "Transactions + Spans", tables: [
          {name: "span_trees", row_estimate: 50, total_bytes: 8_000_000},
          {name: "spans", row_estimate: 400, total_bytes: 99_000_000},
          {name: "transaction_histograms", row_estimate: 100, total_bytes: 1_000_000},
          {name: "transaction_hourly_stats", row_estimate: 20, total_bytes: 200_000}
        ]},
        {name: "Logs", tables: [{name: "logs", row_estimate: 10, total_bytes: 5_000}]}
      ],
      counts: {spans: 400 + 1000},
      data_span: [
        {table: "events", days: 30.0},
        {table: "span_trees", days: 10.0},
        {table: "transaction_histograms", days: 4.0},
        {table: "logs", days: 0.5}
      ]
    }

    usage = StorageStats.daily_usage(snap)

    assert_equal({bytes_per_day: 1_000_000, rows_per_day: 100, days: 30.0}, usage[:events_data_retention_days])
    # Frozen legacy spans bytes/rows are excluded; the row count is the packed span_count.
    assert_equal({bytes_per_day: 800_000, rows_per_day: 100, days: 10.0}, usage[:spans_data_retention_days])
    # Aggregates are the histogram and hourly-stats tables together.
    assert_equal({bytes_per_day: 300_000, rows_per_day: 30, days: 4.0}, usage[:histograms_retention_days])
    assert_nil usage[:logs_data_retention_days], "under a day of data is too short to call a daily figure"
    assert_nil usage[:transactions_data_retention_days], "no span for transactions"
  end

  # Deleting a log fires the trigger that deletes its search-index entries, so
  # a day of logs costs its share of the logs_fts shadow tables too — on Booko
  # (Oct 2026), 35.8 GB of index against 28.7 GB of logs.
  test "daily_usage counts the logs search index in a day of logs, but not its rows" do
    snap = {
      groups: [{name: "Logs", tables: [
        {name: "logs", row_estimate: 1000, total_bytes: 10_000},
        {name: "logs_fts_data", row_estimate: 1300, total_bytes: 12_000},
        {name: "logs_fts_idx", row_estimate: 200, total_bytes: 500},
        {name: "logs_fts_docsize", row_estimate: 1000, total_bytes: 1_500},
        {name: "logs_fts", row_estimate: 1000, total_bytes: 0}
      ]}],
      data_span: [{table: "logs", days: 10.0}]
    }

    usage = StorageStats.daily_usage(snap)[:logs_data_retention_days]

    assert_equal 2_400, usage[:bytes_per_day], "logs + their FTS shadow tables over 10 days"
    assert_equal 100, usage[:rows_per_day], "rows are log lines, not index entries"
  end

  test "daily_usage is empty before the first deep pass" do
    assert_equal({}, StorageStats.daily_usage(nil))
    assert_equal({}, StorageStats.daily_usage({groups: [], data_span: []}))
  end
end
