# frozen_string_literal: true

require "test_helper"

module Mcp
  class McpControllerTest < ActionDispatch::IntegrationTest
    setup do
      @token = "test-mcp-token-#{SecureRandom.hex(8)}"
      ENV["MCP_AUTH_TOKEN"] = @token
    end

    teardown do
      ENV.delete("MCP_AUTH_TOKEN")
    end

    test "get_status reports version, storage, and compression from the snapshot" do
      fake = {
        total: 700_000_000,
        collected_at: Time.utc(2026, 6, 28, 6, 20),
        groups: [{name: "Transactions + Spans", base: "TransactionsSpansRecord", tables: [
          {name: "spans", row_estimate: 1_111_915, table_bytes: 503_000_000, index_bytes: 166_000_000, total_bytes: 669_000_000},
          {name: "span_trees", row_estimate: 302, table_bytes: 1_300_000, index_bytes: 36_000, total_bytes: 1_336_000}
        ]}],
        compression: [{name: "Spans", rows: 302, sample: 100, ratio: 9.8,
                       stored_bytes: 1_336_000, original_bytes: 13_092_800, saved_bytes: 11_756_800}]
      }

      queues = {"splat.events" => {ready: 5, reserved: 1, buried: 0, delayed: 0}}
      with_stub(StorageStats, :snapshot, -> { fake }) do
        with_stub(Ingest::Tuber, :queue_depths, -> { queues }) do
          call_tool("get_status", {})
        end
      end

      assert_response :success
      text = JSON.parse(response.body).dig("result", "content", 0, "text").to_s
      assert_match(/\*\*Version:\*\* #{Regexp.escape(Splat::VERSION)}/o, text)
      assert_match(/span_trees/, text)
      assert_match(/### Compression/, text)
      assert_match(/9\.8×/, text)
      assert_match(/### Queues/, text)
      assert_match(/splat\.events/, text)
    end

    test "get_status splits data from index bytes, ranks indexes, and flags uncompressed tables" do
      fake = {
        total: 90_000_000_000,
        collected_at: Time.utc(2026, 7, 16, 21, 35),
        deep_collected_at: Time.utc(2026, 7, 16, 3, 0),
        groups: [{name: "Transactions + Spans", base: "TransactionsSpansRecord", tables: [
          {name: "transactions", row_estimate: 5_470_176, table_bytes: 27_000_000_000,
           index_bytes: 16_200_000_000, total_bytes: 43_200_000_000,
           indexes: [{name: "index_transactions_on_duration", bytes: 3_900_000_000},
             {name: "index_transactions_on_project_id_and_environment", bytes: 3_100_000_000}]},
          {name: "span_trees", row_estimate: 4_353_596, table_bytes: 13_000_000_000,
           index_bytes: 600_000_000, total_bytes: 13_600_000_000, indexes: []}
        ]}],
        compression: [{name: "Spans", rows: 4_353_596, sample: 500, ratio: 11.0,
                       stored_bytes: 10_100_000_000, original_bytes: 111_100_000_000,
                       saved_bytes: 101_000_000_000}]
      }

      with_stub(StorageStats, :snapshot, -> { fake }) do
        with_stub(Ingest::Tuber, :queue_depths, -> { {} }) do
          call_tool("get_status", {})
        end
      end

      assert_response :success
      text = JSON.parse(response.body).dig("result", "content", 0, "text").to_s

      # Data and index bytes are reported separately, not just as a total.
      assert_match(/\| transactions \| 5470176 \| 25\.1 GB \| 15\.1 GB \| 40\.2 GB \|/, text)
      # Per-index detail, biggest first.
      assert_match(/### Largest indexes/, text)
      assert_match(/index_transactions_on_duration.*3\.63 GB/, text)
      assert_operator text.index("index_transactions_on_duration"), :<,
        text.index("index_transactions_on_project_id_and_environment"),
        "indexes should be ranked biggest-first"
      # The configured window, which the observed data span can't reveal.
      assert_match(/### Retention settings \(configured\)/, text)
      # An uncompressed table is named as such rather than silently absent.
      assert_match(/Transactions \(plain-JSON measurements, slimmed at ingest\).*not compressed/, text)
      # Table sizes carry the deep pass's timestamp, not the 15-min one.
      assert_match(/\*\*Table sizes from:\*\* 2026-07-16T03:00:00Z/, text)
    end

    test "get_status renders a snapshot written before per-index sizes were collected" do
      fake = {
        total: 700_000_000,
        collected_at: Time.utc(2026, 6, 28, 6, 20),
        groups: [{name: "Transactions + Spans", base: "TransactionsSpansRecord", tables: [
          {name: "span_trees", row_estimate: 302, table_bytes: 1_300_000,
           index_bytes: 36_000, total_bytes: 1_336_000}
        ]}],
        compression: []
      }

      with_stub(StorageStats, :snapshot, -> { fake }) do
        with_stub(Ingest::Tuber, :queue_depths, -> { {} }) do
          call_tool("get_status", {})
        end
      end

      assert_response :success
      text = JSON.parse(response.body).dig("result", "content", 0, "text").to_s
      assert_match(/span_trees/, text)
      # No :indexes key and no :deep_collected_at — render, don't crash.
      refute_match(/### Largest indexes/, text)
      refute_match(/Table sizes from/, text)
    end

    test "search_slow_transactions passes valid tags hash through to Transaction.slow" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"user_id" => "123", "feature" => "x"}})
        assert_response :success
        assert_equal({"user_id" => "123", "feature" => "x"}, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions with no tags passes nil through" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {})
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    # ---- Window ceilings come from retention, not a blanket 168. ----

    test "search_slow_transactions reaches back to raw transaction retention" do
      cap_hours = Setting.instance.transactions_data_retention_days * 24
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"time_range_hours" => 1000})
        assert_response :success
        assert_operator 1000, :<=, cap_hours, "fixture retention should exceed the old 168h cap"
        window = captured[:kwargs][:time_range]
        assert_in_delta 1000 * 3600, window.end - window.begin, 60
        refute_match(/window was reduced/, tool_text)
      end
    end

    test "search_slow_transactions clamps past retention and says so" do
      cap_hours = Setting.instance.transactions_data_retention_days * 24
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"time_range_hours" => cap_hours + 5000})
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta cap_hours * 3600, window.end - window.begin, 60
        assert_match(/window was reduced to #{cap_hours}h/, tool_text)
      end
    end

    test "search_logs is capped by the shorter log retention" do
      cap_hours = Setting.instance.logs_data_retention_days * 24
      call_tool("search_logs", {"time_range_hours" => cap_hours + 100})
      assert_response :success
      assert_match(/window was reduced to #{cap_hours}h/, tool_text)
    end

    test "get_transaction_stats reaches back to the long rollup retention" do
      # The rollups outlive raw rows by design, so a window far past raw
      # retention is legitimate here and must not be flagged as truncated.
      call_tool("get_transaction_stats", {"time_range_hours" => 2000})
      assert_response :success
      refute_match(/window was reduced/, tool_text)
    end

    test "search_slow_transactions rejects invalid tag key without hitting Transaction.slow" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"bad key" => "x"}})
        assert_response :success
        refute captured[:called], "Transaction.slow should not be called for invalid tag keys"
        body = JSON.parse(response.body)
        text = body.dig("result", "content", 0, "text").to_s
        assert_match(/Invalid tag key/, text)
      end
    end

    test "search_slow_transactions coerces non-string tag values to strings" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"user_id" => 42}})
        assert_response :success
        assert_equal({"user_id" => "42"}, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions ignores empty tags hash" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {}})
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    test "get_issue_events does not crash when an event payload is nil" do
      # Old events can have payload purged by retention while the event row stays.
      # format_issue_events used to dig into event.payload['environment'] and
      # raise 'undefined method [] for nil'. The fix reads denormalized columns.
      project = projects(:one)
      issue = Issue.create!(
        project: project,
        fingerprint: "purged-payload-test",
        title: "Test",
        first_seen: 2.weeks.ago,
        last_seen: 2.weeks.ago
      )
      Event.create!(
        project: project,
        issue: issue,
        event_id: SecureRandom.uuid,
        timestamp: 2.weeks.ago,
        environment: "production",
        server_name: "test-host",
        payload: nil
      )

      call_tool("get_issue_events", {"issue_id" => issue.id})
      assert_response :success
      body = JSON.parse(response.body)
      text = body.dig("result", "content", 0, "text").to_s
      assert_match(/Environment:.*production/, text)
      assert_match(/Server:.*test-host/, text)
    end

    private

    test "search_logs returns matching logs" do
      project = projects(:one)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :error, source: "sentry", body: "mcp searchable log", trace_id: "mcp-trace", payload: {})

      call_tool("search_logs", {"query" => "mcp searchable", "level" => "error"})
      assert_response :success
      assert_match "mcp searchable log", tool_text
    end

    test "search_logs scopes to a single release" do
      project = projects(:one)
      %w[1.11.1 1.12.0].each do |release|
        Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
          level: :error, source: "sentry", body: "boom from #{release}", release: release, payload: {})
      end

      call_tool("search_logs", {"release" => "1.12.0"})
      assert_response :success
      assert_match "boom from 1.12.0", tool_text
      refute_match(/boom from 1\.11\.1/, tool_text)
    end

    test "search_logs without a project spans every project" do
      seed_log_in(projects(:one), "alpha inbound line")
      seed_log_in(projects(:two), "beta inbound line")

      call_tool("search_logs", {"query" => "inbound"})
      assert_response :success
      assert_match "alpha inbound line", tool_text
      assert_match "beta inbound line", tool_text
    end

    test "search_logs narrows to one project by slug, name, or id" do
      seed_log_in(projects(:one), "alpha inbound line")
      seed_log_in(projects(:two), "beta inbound line")

      [projects(:two).slug, projects(:two).name, projects(:two).id.to_s].each do |ref|
        call_tool("search_logs", {"query" => "inbound", "project" => ref})
        assert_response :success
        assert_match "beta inbound line", tool_text, "expected project match for #{ref.inspect}"
        assert_no_match(/alpha inbound line/, tool_text, "leaked other project for #{ref.inspect}")
      end
    end

    test "an unknown project is a bad request naming the real projects" do
      call_tool("search_logs", {"query" => "inbound", "project" => "no-such-project"})
      assert_response :bad_request

      message = JSON.parse(response.body).dig("error", "message").to_s
      assert_match "Unknown project: no-such-project", message
      assert_match projects(:one).slug, message
    end

    test "list_recent_issues honours the project filter" do
      seed_issue_in(projects(:one), "AlphaError")
      seed_issue_in(projects(:two), "BetaError")

      call_tool("list_recent_issues", {"status" => "all", "project" => projects(:one).slug})
      assert_response :success
      assert_match "AlphaError", tool_text
      assert_no_match(/BetaError/, tool_text)
    end

    test "a project slug matches regardless of case" do
      seed_log_in(projects(:two), "beta inbound line")

      call_tool("search_logs", {"query" => "inbound", "project" => projects(:two).slug.upcase})
      assert_response :success
      assert_match "beta inbound line", tool_text
    end

    test "a blank project is an error, not every project" do
      seed_log_in(projects(:one), "alpha inbound line")

      call_tool("search_logs", {"query" => "inbound", "project" => "   "})
      assert_response :bad_request
      assert_no_match(/alpha inbound line/, response.body)
    end

    test "an ambiguous project name asks for a slug instead of guessing" do
      duplicate = Project.create!(name: projects(:one).name, slug: "one-duplicate",
        public_key: "dup-key")

      call_tool("search_logs", {"query" => "inbound", "project" => projects(:one).name})
      assert_response :bad_request

      message = JSON.parse(response.body).dig("error", "message").to_s
      assert_match "matches 2 projects by name", message
      assert_match duplicate.slug, message
      assert_match projects(:one).slug, message
    end

    test "a slug still wins over another project's identical name" do
      # Project A's slug == Project B's name: naming it must not silently
      # resolve to whichever row the DB returned first.
      named_like_a_slug = Project.create!(name: projects(:two).slug, slug: "shadow-check",
        public_key: "shadow-key")
      seed_log_in(projects(:two), "beta inbound line")
      seed_log_in(named_like_a_slug, "shadow inbound line")

      call_tool("search_logs", {"query" => "inbound", "project" => projects(:two).slug})
      assert_response :success
      assert_match "beta inbound line", tool_text
      assert_no_match(/shadow inbound line/, tool_text)
    end

    test "list_recent_issues filters by environment as seen-in, not belongs-to" do
      both = seed_issue_in(projects(:one), "SpansEnvsError")
      staging_only = seed_issue_in(projects(:one), "StagingOnlyError")
      IssueFacet.reset_throttle!
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: both.id, values: {environment: "production"})
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: both.id, values: {environment: "staging"})
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: staging_only.id, values: {environment: "staging"})

      call_tool("list_recent_issues", {"status" => "all", "environment" => "production"})
      assert_response :success
      assert_match "SpansEnvsError", tool_text
      assert_no_match(/StagingOnlyError/, tool_text)

      # The cross-environment issue also shows under staging — that's the point.
      call_tool("list_recent_issues", {"status" => "all", "environment" => "staging"})
      assert_response :success
      assert_match "SpansEnvsError", tool_text
      assert_match "StagingOnlyError", tool_text
    end

    test "search_issues combines the environment filter with the project filter" do
      mine = seed_issue_in(projects(:one), "SharedNameError")
      theirs = seed_issue_in(projects(:two), "SharedNameError")
      IssueFacet.reset_throttle!
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: mine.id, values: {environment: "production"})
      IssueFacet.harvest!(project_id: projects(:two).id, issue_id: theirs.id, values: {environment: "production"})

      call_tool("search_issues", {"query" => "SharedName", "environment" => "production",
                                  "project" => projects(:two).slug})
      assert_response :success
      assert_match "##{theirs.id}", tool_text
      assert_no_match(/##{mine.id}\b/, tool_text)
    end

    test "search_issues filters by release" do
      old = seed_issue_in(projects(:one), "OldReleaseError")
      fresh = seed_issue_in(projects(:one), "NewReleaseError")
      IssueFacet.reset_throttle!
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: old.id, values: {release: "v1.0.0"})
      IssueFacet.harvest!(project_id: projects(:one).id, issue_id: fresh.id, values: {release: "v2.0.0"})

      call_tool("search_issues", {"release" => "v2.0.0"})
      assert_response :success
      assert_match "NewReleaseError", tool_text
      assert_no_match(/OldReleaseError/, tool_text)
    end

    test "search_issues treats LIKE wildcards in the query as literals" do
      seed_issue_in(projects(:one), "Net_HTTPError")
      seed_issue_in(projects(:one), "NetXHTTPError")

      call_tool("search_issues", {"query" => "Net_HTTP"})
      assert_response :success
      assert_match "Net_HTTPError", tool_text
      assert_no_match(/NetXHTTPError/, tool_text)
    end

    test "get_log returns a record by log_id" do
      project = projects(:one)
      id = SecureRandom.uuid_v7
      Log.create!(project_id: project.id, log_id: id, timestamp: Time.current,
        level: :info, source: "sentry", body: "fetch me",
        payload: {"attributes" => {"sentry.environment" => "production"}})

      call_tool("get_log", {"log_id" => id})
      assert_response :success
      assert_match "fetch me", tool_text
      assert_match "Attributes", tool_text
    end

    test "get_trace_logs collects logs for a trace" do
      project = projects(:one)
      2.times do |i|
        Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: i.minutes.ago,
          level: :info, source: "sentry", body: "trace line #{i}", trace_id: "shared-trace", payload: {})
      end

      call_tool("get_trace_logs", {"trace_id" => "shared-trace"})
      assert_response :success
      assert_match "trace line 0", tool_text
      assert_match "trace line 1", tool_text
    end

    test "get_transaction surfaces the promoted trace_id so logs can be cross-referenced" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120,
        trace_id: "txn-trace-xyz")

      call_tool("get_transaction", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "txn-trace-xyz", tool_text
      assert_match "get_trace_logs", tool_text
    end

    test "get_transaction lists the errors thrown during the request" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "BooksController#show", duration: 240,
        trace_id: "txn-with-error")
      event = Event.create_from_sentry_payload!(
        SecureRandom.uuid,
        {"exception" => {"values" => [{"type" => "IO::TimeoutError", "value" => "user specified timeout"}]},
         "timestamp" => "2026-07-17T08:00:00Z",
         "contexts" => {"trace" => {"trace_id" => "txn-with-error"}}},
        project
      )

      call_tool("get_transaction", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "Errors in this request", tool_text
      assert_match "IO::TimeoutError", tool_text
      assert_match "get_event", tool_text
      assert_match "id #{event.id}", tool_text
    end

    test "get_transaction_spans renders the waterfall from the span_tree blob" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120)
      t0 = Time.current
      tree = {"trace_id" => "tr", "spans" => [
        {"span_id" => "s1", "parent_span_id" => nil, "op" => "db.sql.active_record", "status" => "ok",
         "description" => "SELECT * FROM products", "ts" => t0, "end_ts" => t0 + 0.03,
         "depth" => 0, "sequence" => 0, "tags" => {}, "data" => {}}
      ]}
      SpanTree.create_from_tree!(project_id: project.id, transaction_id: txn.transaction_id,
        timestamp: txn.timestamp, tree: tree, span_count: 1, spans_truncated: false)

      call_tool("get_transaction_spans", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "db.sql.active_record", tool_text
      assert_match "SELECT * FROM products", tool_text
    end

    test "get_transaction_spans falls back to legacy span rows during the dual-read window" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120)
      t0 = Time.current
      Span.create!(project_id: project.id, transaction_id: txn.transaction_id,
        span_id: "s1", op: "http.client", description: "GET https://api.example",
        timestamp: t0, end_timestamp: t0 + 0.04, depth: 0, sequence: 0)

      call_tool("get_transaction_spans", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "http.client", tool_text
      assert_match "GET https://api.example", tool_text
    end

    test "list_monitors renders registered monitors with state and schedule" do
      project = projects(:one)
      CronMonitor.create!(
        project: project, slug: "meili-flush",
        schedule_type: "interval", schedule_value: "1", schedule_unit: "minute",
        checkin_margin: 5, last_status: "ok", last_checkin_at: 2.minutes.ago,
        last_ok_at: 2.minutes.ago, last_duration: 0.42, environment: "production",
        state: "ok"
      )
      CronMonitor.create!(
        project: project, slug: "nightly-report",
        schedule_type: "crontab", schedule_value: "0 2 * * *",
        last_status: "error", last_checkin_at: 1.hour.ago, state: "error"
      )

      call_tool("list_monitors", {})
      assert_response :success
      assert_match "meili-flush — ok", tool_text
      assert_match "every 1 minute (+5m margin)", tool_text
      assert_match "nightly-report — error", tool_text
      assert_match "cron 0 2 * * *", tool_text

      call_tool("list_monitors", {"state" => "error"})
      assert_match "nightly-report", tool_text
      refute_match "meili-flush", tool_text
    end

    test "list_monitors explains the empty state" do
      call_tool("list_monitors", {})
      assert_response :success
      assert_match "No monitors registered", tool_text
    end

    def tool_text
      JSON.parse(response.body).dig("result", "content", 0, "text").to_s
    end

    def seed_log_in(project, body)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :error, source: "sentry", body: body, payload: {})
    end

    def seed_issue_in(project, exception_type)
      Issue.create!(project: project, fingerprint: "#{project.slug}::#{exception_type}",
        title: "#{exception_type}: something broke", exception_type: exception_type,
        first_seen: Time.current, last_seen: Time.current)
    end

    def call_tool(name, arguments)
      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {name: name, arguments: arguments}
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@token}"
        }
    end

    # Swap Transaction.slow for a recording stub for the block.
    # Captured hash exposes { called:, kwargs: } so tests can assert on inputs.
    def with_slow_stub
      captured = {called: false, kwargs: nil}
      klass = Transaction.singleton_class
      original = Transaction.method(:slow)
      klass.send(:define_method, :slow) do |**kwargs|
        captured[:called] = true
        captured[:kwargs] = kwargs
        []
      end
      yield captured
    ensure
      klass.send(:define_method, :slow, original)
    end
  end
end
