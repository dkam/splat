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

    test "initialize tells the client to call serially" do
      initialize_with("2025-06-18")

      assert_response :success
      instructions = JSON.parse(response.body).dig("result", "instructions").to_s
      assert_match(/SERIALLY/, instructions)
      assert_match(/no server-side statement timeout/i, instructions)
    end

    test "initialize negotiates the client's protocol version" do
      initialize_with("2025-06-18")
      assert_equal "2025-06-18", JSON.parse(response.body).dig("result", "protocolVersion")

      # An unrecognised version falls back to the SDK's default rather than
      # failing the handshake.
      initialize_with("1999-01-01")
      assert_response :success
      assert_match(/\A20\d\d-/, JSON.parse(response.body).dig("result", "protocolVersion").to_s)
    end

    # `instructions` didn't exist before 2025-03-26. The old hand-rolled server
    # advertised 2024-11-05 and sent it anyway; the SDK is honest about it, so a
    # client pinned that far back loses the note. Asserted so the loss is a
    # deliberate, visible property rather than a silent one.
    test "a client pinned to 2024-11-05 gets no instructions" do
      initialize_with("2024-11-05")

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "2024-11-05", body.dig("result", "protocolVersion")
      assert_nil body.dig("result", "instructions")
    end

    # A notification has no id and must not be answered with a JSON-RPC frame.
    test "notifications/initialized is accepted with no body" do
      post "/mcp",
        params: {jsonrpc: "2.0", method: "notifications/initialized"}.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@token}"}

      assert_response :accepted
      assert_empty response.body
    end

    test "ping is answered" do
      post "/mcp",
        params: {jsonrpc: "2.0", id: 9, method: "ping"}.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@token}"}

      assert_response :success
      assert_equal({}, JSON.parse(response.body)["result"])
    end

    test "tools/list advertises read-only and write tools distinctly" do
      post "/mcp",
        params: {jsonrpc: "2.0", id: 2, method: "tools/list", params: {}}.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@token}"}

      assert_response :success
      tools = JSON.parse(response.body).dig("result", "tools").index_by { |t| t["name"] }

      assert_equal true, tools.dig("search_issues", "annotations", "readOnlyHint")
      assert_equal false, tools.dig("resolve_issue", "annotations", "readOnlyHint")
      assert_equal false, tools.dig("resolve_issue", "annotations", "destructiveHint")
    end

    test "tools/list advertises output schemas only where they earn their tokens" do
      post "/mcp",
        params: {jsonrpc: "2.0", id: 2, method: "tools/list", params: {}}.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@token}"}

      assert_response :success
      tools = JSON.parse(response.body).dig("result", "tools").index_by { |t| t["name"] }

      assert tools.dig("list_recent_issues", "outputSchema"),
        "a list of rows is worth handing over structured"
      # Prose with units and caveats — a structured copy would be the same text
      # in braces at twice the size. See SplatMcpServer.output_schemas.
      assert_nil tools.dig("get_event", "outputSchema")
      assert_nil tools.dig("get_transaction_spans", "outputSchema")
    end

    # ---- Argument validation (validate_tool_call_arguments). ----

    test "an unknown enum value is refused instead of quietly answering something else" do
      call_tool("list_recent_issues", {"status" => "opened"})

      message = tool_error
      assert_match(/status/, message)
      assert_match(/resolved/, message, "the message should name the accepted values")
    end

    test "a numeric argument sent as a string is still accepted" do
      seed_issue_in(projects(:one), "StringLimitError")

      # Models routinely write "5" where the schema says integer, and every
      # reader here goes through &.to_i. The schema says so explicitly now.
      call_tool("list_recent_issues", {"status" => "all", "limit" => "5"})

      assert_response :success
      assert_equal false, JSON.parse(response.body).dig("result", "isError")
      assert_match "StringLimitError", tool_text
    end

    test "a non-numeric limit is refused rather than silently becoming the minimum" do
      call_tool("list_recent_issues", {"status" => "all", "limit" => "twenty"})

      assert_match(/limit/, tool_error)
    end

    test "a project given as a bare integer resolves" do
      seed_issue_in(projects(:two), "NumericProjectError")

      call_tool("list_recent_issues", {"status" => "all", "project" => projects(:two).id})

      assert_response :success
      assert_match "NumericProjectError", tool_text
    end

    # ---- Structured content. ----

    test "list_recent_issues carries a structured copy alongside the markdown" do
      issue = seed_issue_in(projects(:one), "StructuredError")

      call_tool("list_recent_issues", {"status" => "all"})
      assert_response :success

      # The markdown is still the answer; structuredContent is additive.
      assert_match "StructuredError", tool_text

      row = tool_structured["issues"].find { |i| i["id"] == issue.id }
      assert row, "expected issue #{issue.id} in structuredContent, got #{tool_structured.inspect}"
      assert_equal issue.title, row["title"]
      assert_equal "open", row["status"]
      assert_equal projects(:one).name, row["project"]
      assert_match(/\A\d{4}-\d\d-\d\dT/, row["last_seen"], "timestamps go over the wire as ISO 8601")
    end

    # A tool that declares an outputSchema has to carry structuredContent on
    # every success — an empty result is still a result, and validate_tool_call_results
    # (on outside production) would raise if it went missing.
    test "an empty result still carries structured content" do
      call_tool("list_monitors", {})

      assert_response :success
      assert_equal({"monitors" => []}, tool_structured)
    end

    test "find_n_plus_one_endpoints carries wasted time in markdown and structured content" do
      at = (Time.current - 2.hours).beginning_of_hour
      3.times do
        Transaction.create!(project: projects(:one), transaction_id: SecureRandom.uuid,
          transaction_name: "BooksController#show", timestamp: at, duration: 500,
          query_count: 40, has_n_plus_one: true, n_plus_one_time: 96)
      end

      call_tool("find_n_plus_one_endpoints", {})
      assert_response :success

      assert_match(/Wasted/, tool_text)
      assert_match(/288(\.0)?\s*ms/, tool_text)

      row = tool_structured["endpoints"].find { |e| e["transaction_name"] == "BooksController#show" }
      assert row, "expected BooksController#show in structuredContent, got #{tool_structured.inspect}"
      assert_equal 288, row["n_plus_one_time_ms"]
      assert_in_delta 96.0, row["avg_n_plus_one_time_ms"], 0.1
    end

    # ---- Same-named endpoints in different projects. ----
    #
    # Two Rails apps on one instance both have ProductsController#index, and
    # the two share nothing but the convention. On splat-booko the unscoped
    # summary reported p50 4ms for Booko's 137ms endpoint, because C2A2's
    # five-times-larger, much faster traffic swamped it.

    test "a single-endpoint tool refuses to pool an endpoint name two projects share" do
      seed_shared_endpoint
      at = (Time.current - 2.hours).beginning_of_hour

      [
        ["get_endpoint_summary", {}],
        ["get_endpoint_timeseries", {}],
        ["get_transaction_stats", {}],
        ["compare_endpoint_performance",
          {"before_timestamp" => (at + 1.minute).iso8601, "after_timestamp" => (at + 2.minutes).iso8601}]
      ].each do |tool, extra|
        call_tool(tool, {"endpoint" => "ProductsController#index"}.merge(extra))

        message = tool_error
        assert_match "project-one", message, "#{tool} should name the projects to choose from"
        assert_match "project-two", message, "#{tool} should name the projects to choose from"
      end
    end

    test "naming the project answers for that project alone" do
      seed_shared_endpoint

      call_tool("get_endpoint_summary", {"endpoint" => "ProductsController#index", "project" => "project-one"})

      assert_equal false, JSON.parse(response.body).dig("result", "isError")
      assert_match(/Total Requests:\*\* 3\b/, tool_text)
    end

    test "an endpoint name only one project has needs no project argument" do
      seed_shared_endpoint
      seed_txn(projects(:one), "BooksController#show", 120)

      call_tool("get_endpoint_summary", {"endpoint" => "BooksController#show"})

      assert_equal false, JSON.parse(response.body).dig("result", "isError")
      assert_match(/Total Requests:\*\* 1\b/, tool_text)
    end

    # The rollups don't carry release, so the overlap has to be judged on the
    # rows the release filter actually selects. A release string belongs to
    # one app, so filtering by it already says which project is meant.
    test "a release filter that only one project has settles which project is meant" do
      seed_shared_endpoint
      seed_txn(projects(:one), "ProductsController#index", 150, release: "booko-1.0")

      call_tool("get_endpoint_summary", {"endpoint" => "ProductsController#index", "release" => "booko-1.0"})

      assert_equal false, JSON.parse(response.body).dig("result", "isError")
      assert_match(/Total Requests:\*\* 1\b/, tool_text)
    end

    test "get_transaction_stats lists a shared endpoint name once per project" do
      seed_shared_endpoint

      call_tool("get_transaction_stats", {})
      assert_response :success

      rows = tool_structured["top_endpoints"].select { |r| r["transaction_name"] == "ProductsController#index" }
      assert_equal [["Project One", 3], ["Project Two", 10]], rows.map { |r| [r["project"], r["count"]] }.sort
      one, two = rows.sort_by { |r| r["project"] }
      assert_operator one["p95_duration"], :>, 100, "Project One's p95 must come from its own 150ms requests"
      assert_operator two["p95_duration"], :<, 10, "Project Two's p95 must come from its own 4ms requests"

      assert_match(/\| Project One \| ProductsController#index \|/, tool_text)
      assert_match(/\| Project Two \| ProductsController#index \|/, tool_text)
    end

    test "find_n_plus_one_endpoints lists a shared endpoint name once per project" do
      2.times { seed_txn(projects(:one), "BooksController#show", 500, query_count: 40, has_n_plus_one: true) }
      5.times { seed_txn(projects(:two), "BooksController#show", 300, query_count: 30, has_n_plus_one: true) }

      call_tool("find_n_plus_one_endpoints", {})
      assert_response :success

      rows = tool_structured["endpoints"].select { |r| r["transaction_name"] == "BooksController#show" }
      assert_equal [["Project One", 2], ["Project Two", 5]], rows.map { |r| [r["project"], r["n_plus_one_count"]] }.sort
      assert_match(/\| Project One \| BooksController#show \|/, tool_text)
      assert_match(/\| Project Two \| BooksController#show \|/, tool_text)
    end

    # Neither the rollups nor the raw fallback compute a DB or view-time
    # percentile — the histograms are of total duration only — so the summary
    # used to print a p95 of 0ms under a real, non-zero average.
    test "get_endpoint_summary doesn't report a DB or view p95 it never computed" do
      3.times { seed_txn(projects(:one), "BooksController#show", 200, db_time: 80, view_time: 60) }

      call_tool("get_endpoint_summary", {"endpoint" => "BooksController#show"})

      assert_match(/Avg DB Time:\*\* 80ms/, tool_text)
      assert_match(/Avg View Time:\*\* 60ms/, tool_text)
      refute_match(/P95 (DB|View) Time:\*\* 0ms/, tool_text)
    end

    # A window with no requests has no percentiles. They were filled with 0, so
    # a misspelt endpoint name read as the fastest endpoint in the app.
    test "get_transaction_stats gives no figures, not 0ms, for an endpoint with no requests" do
      seed_txn(projects(:one), "BooksController#show", 200)

      call_tool("get_transaction_stats", {"endpoint" => "BookController#show"})

      assert_equal false, JSON.parse(response.body).dig("result", "isError"), tool_text
      assert_equal 0, tool_structured["total_count"]
      assert_equal({}, tool_structured["percentiles"].compact)
      assert_match(/No transactions/, tool_text)
      refute_match(/\b0ms\b/, tool_text)
    end

    test "get_transaction_stats gives no average, min or max for an empty window" do
      call_tool("get_transaction_stats", {})

      assert_equal({}, tool_structured["percentiles"].compact)
      refute_match(/\b0ms\b/, tool_text)
    end

    # The overall figures are one number each, so pooling projects gives one
    # that describes neither: the splat-booko shape again, without an endpoint.
    test "get_transaction_stats with no project gives each project its own overall figures" do
      seed_shared_endpoint

      call_tool("get_transaction_stats", {})

      assert_equal 13, tool_structured["total_count"]
      assert_equal({}, tool_structured["percentiles"].compact, "a pooled p50 describes neither project")
      by_project = tool_structured["by_project"].index_by { |r| r["project"] }
      assert_equal [3, 10], by_project.values_at("Project One", "Project Two").map { |r| r["count"] }
      assert_operator by_project["Project One"]["p50"], :>, 100
      assert_operator by_project["Project Two"]["p50"], :<, 10
      assert_match(/\| Project One \| 3 \|/, tool_text)
      assert_match(/\| Project Two \| 10 \|/, tool_text)
    end

    test "get_transaction_stats with no project still gives overall figures when one project has traffic" do
      3.times { seed_txn(projects(:one), "BooksController#show", 150) }

      call_tool("get_transaction_stats", {})

      assert_operator tool_structured.dig("percentiles", "p50"), :>, 100
      assert_equal [["Project One", 3]], tool_structured["by_project"].map { |r| [r["project"], r["count"]] }
    end

    # ---- Per-host views. ----
    #
    # web01 stalled on splat-booko on 2026-10-08 (one worker OOM-killed) and no
    # tool could say which slow requests were web01's, or show its throughput
    # dropping while web02/web03 picked up the load. server_name is stored on
    # every transaction; these tools now take it and show it.

    test "search_slow_transactions narrows to one host and names the host on every row" do
      2.times { seed_txn(projects(:one), "BooksController#show", 3000, server_name: "web01") }
      seed_txn(projects(:one), "BooksController#show", 4000, server_name: "web02")

      call_tool("search_slow_transactions", {})
      assert_equal 2, tool_text.scan("Server: web01").size
      assert_equal 1, tool_text.scan("Server: web02").size

      call_tool("search_slow_transactions", {"server_name" => "web01"})
      assert_match(/Found 2 transaction/, tool_text)
      refute_match "web02", tool_text
    end

    test "get_transactions_by_endpoint narrows to one host" do
      seed_txn(projects(:one), "BooksController#show", 100, server_name: "web01")
      seed_txn(projects(:one), "BooksController#show", 100, server_name: "web02")

      call_tool("get_transactions_by_endpoint", {"endpoint" => "BooksController#show", "server_name" => "web01"})

      assert_match(/Showing:\*\* 1 transaction/, tool_text)
      assert_match "**Server:** web01", tool_text
      refute_match "web02", tool_text
    end

    test "get_transaction_stats for one host counts that host's requests alone" do
      3.times { seed_txn(projects(:one), "BooksController#show", 3000, server_name: "web01") }
      10.times { seed_txn(projects(:one), "BooksController#show", 50, server_name: "web02") }
      seed_txn(projects(:one), "WorksController#show", 50, server_name: "web02")

      call_tool("get_transaction_stats", {"server_name" => "web01", "time_range_hours" => 3})

      assert_equal false, JSON.parse(response.body).dig("result", "isError"), tool_text
      assert_equal 3, tool_structured["total_count"]
      assert_operator tool_structured.dig("percentiles", "p50"), :>, 2000
      assert_equal [["BooksController#show", 3]],
        tool_structured["top_endpoints"].map { |r| [r["transaction_name"], r["count"]] }
      assert_operator tool_structured["top_endpoints"].first["p95_duration"], :>, 2000
      assert_match "**Server:** web01", tool_text
    end

    # The rollups don't carry server_name, so a host filter reads raw rows, and
    # server_name has no index — only the window bounds the scan.
    test "a host filter on get_transaction_stats caps the window" do
      call_tool("get_transaction_stats", {"server_name" => "web01", "time_range_hours" => 48})
      assert_match(/reduced to 6h/, tool_text)

      call_tool("get_transaction_stats", {"server_name" => "web01",
        "start_time" => 2.days.ago.iso8601, "end_time" => 1.day.ago.iso8601})
      assert_match(/capped at 6h/, tool_error)
    end

    test "get_host_breakdown shows each host's count, avg and max per bucket, zeros included" do
      base = (Time.current - 30.minutes).beginning_of_minute
      [[base, "web01", 100], [base, "web01", 100], [base, "web01", 400],
        [base, "web02", 50], [base + 1.minute, "web02", 70]].each do |at, host, ms|
        Transaction.create!(project: projects(:one), transaction_id: SecureRandom.uuid,
          transaction_name: "BooksController#show", timestamp: at + 5.seconds, duration: ms, server_name: host)
      end

      call_tool("get_host_breakdown", {
        "start_time" => base.iso8601, "end_time" => (base + 2.minutes).iso8601, "bucket_minutes" => 1
      })
      assert_equal false, JSON.parse(response.body).dig("result", "isError"), tool_text

      rows = tool_structured["rows"].index_by { |r| [r["bucket_start"], r["server_name"]] }
      first, second = base.utc.iso8601, (base + 1.minute).utc.iso8601
      assert_equal [3, 200.0, 400], rows[[first, "web01"]].values_at("count", "avg_duration", "max_duration")
      assert_equal [1, 50.0, 50], rows[[first, "web02"]].values_at("count", "avg_duration", "max_duration")
      # A host that served nothing in a bucket is the signal, not a gap.
      assert_equal 0, rows[[second, "web01"]]["count"]
      assert_equal 1, rows[[second, "web02"]]["count"]

      assert_match(/\| Bucket start \| web01 \| web02 \|/, tool_text)
    end

    test "get_host_breakdown narrows to one host and caps the window" do
      seed_txn(projects(:one), "BooksController#show", 100, server_name: "web01")
      seed_txn(projects(:one), "BooksController#show", 100, server_name: "web02")

      call_tool("get_host_breakdown", {"server_name" => "web01", "hours" => 3})
      assert_equal ["web01"], tool_structured["rows"].map { |r| r["server_name"] }.uniq

      call_tool("get_host_breakdown", {"hours" => 48})
      assert_match(/reduced to 6h/, tool_text)
    end

    # Two apps can run on one host, and can share an endpoint name; a cell
    # averaging both describes neither.
    test "get_host_breakdown keeps each project's requests on a shared host apart" do
      3.times { seed_txn(projects(:one), "ProductsController#index", 150, server_name: "web01") }
      10.times { seed_txn(projects(:two), "ProductsController#index", 4, server_name: "web01") }

      call_tool("get_host_breakdown", {"endpoint" => "ProductsController#index", "hours" => 3})

      assert_equal false, JSON.parse(response.body).dig("result", "isError"), tool_text
      served = tool_structured["rows"].select { |r| r["count"].positive? }
      assert_equal [["Project One", 3, 150.0], ["Project Two", 10, 4.0]],
        served.map { |r| r.values_at("project", "count", "avg_duration") }.sort
      assert_match(/\| web01 \(Project One\) \| web01 \(Project Two\) \|/, tool_text)
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
        refute_match(/duration was reduced/, tool_text)
      end
    end

    test "search_slow_transactions clamps past retention and says so" do
      cap_hours = Setting.instance.transactions_data_retention_days * 24
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"time_range_hours" => cap_hours + 5000})
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta cap_hours * 3600, window.end - window.begin, 60
        assert_match(/duration was reduced to #{cap_hours}h/, tool_text)
      end
    end

    test "search_logs is capped by the shorter log retention" do
      cap_hours = Setting.instance.logs_data_retention_days * 24
      call_tool("search_logs", {"time_range_hours" => cap_hours + 100})
      assert_response :success
      assert_match(/duration was reduced to #{cap_hours}h/, tool_text)
    end

    test "get_transaction_stats reaches back to the long rollup retention" do
      # The rollups outlive raw rows by design, so a window far past raw
      # retention is legitimate here and must not be flagged as truncated.
      call_tool("get_transaction_stats", {"time_range_hours" => 2000})
      assert_response :success
      refute_match(/duration was reduced/, tool_text)
    end

    test "search_slow_transactions passes release and a duration band through" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {
          "release" => "1.12.0", "min_duration_ms" => 10_000, "max_duration_ms" => 20_000
        })
        assert_response :success
        assert_equal "1.12.0", captured[:kwargs][:release]
        assert_equal 10_000, captured[:kwargs][:threshold_ms]
        assert_equal 20_000, captured[:kwargs][:max_duration_ms]
      end
    end

    test "search_slow_transactions ignores a non-positive max_duration_ms" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"max_duration_ms" => 0})
        assert_response :success
        assert_nil captured[:kwargs][:max_duration_ms], "0 would exclude every row"
      end
    end

    # ---- Absolute window bounds. ----

    test "end_time anchors the window to a past moment" do
      anchor = 10.days.ago.change(usec: 0)
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"end_time" => anchor.utc.iso8601, "time_range_hours" => 12})
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta anchor.to_i, window.end.to_i, 1
        assert_in_delta (anchor - 12.hours).to_i, window.begin.to_i, 1
      end
    end

    test "start_time and end_time give a fully explicit window" do
      from = 10.days.ago.change(usec: 0)
      to = 9.days.ago.change(usec: 0)
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {
          "start_time" => from.utc.iso8601, "end_time" => to.utc.iso8601, "time_range_hours" => 999
        })
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta from.to_i, window.begin.to_i, 1
        assert_in_delta to.to_i, window.end.to_i, 1, "hours must be ignored when both bounds are given"
      end
    end

    test "omitting both bounds behaves exactly as before" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"time_range_hours" => 6})
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta Time.current.to_i, window.end.to_i, 5
        assert_in_delta 6 * 3600, window.end - window.begin, 5
      end
    end

    test "a window entirely before retention is named as expired, not returned empty" do
      cap_days = Setting.instance.transactions_data_retention_days
      gone = (cap_days + 30).days.ago
      call_tool("search_slow_transactions", {"end_time" => gone.utc.iso8601, "time_range_hours" => 6})

      assert_match(/retained for #{cap_days} days/, tool_error)
      assert_match(/Nothing from it remains/, tool_error)
    end

    test "a window straddling the retention cutoff is pulled forward with a note" do
      cap_days = Setting.instance.transactions_data_retention_days
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {
          "start_time" => (cap_days + 10).days.ago.utc.iso8601, "end_time" => Time.current.utc.iso8601
        })
        assert_response :success
        window = captured[:kwargs][:time_range]
        assert_in_delta cap_days.days.ago.to_i, window.begin.to_i, 60
        assert_match(/before the #{cap_days}d retention limit/, tool_text)
      end
    end

    test "an inverted window is rejected" do
      call_tool("search_slow_transactions", {
        "start_time" => 1.day.ago.utc.iso8601, "end_time" => 2.days.ago.utc.iso8601
      })
      assert_match(/end_time must be after start_time/, tool_error)
    end

    test "an unparseable timestamp says which argument and what format" do
      call_tool("search_slow_transactions", {"end_time" => "last tuesday"})
      assert_match(/Invalid end_time/, tool_error)
      assert_match(/ISO 8601/, tool_error)
    end

    test "output labels an absolute window with its bounds, not 'last Nh'" do
      project = projects(:one)
      at = 5.days.ago
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: at,
        level: :error, source: "sentry", body: "historical line", payload: {})

      call_tool("search_logs", {"end_time" => (at + 1.hour).utc.iso8601, "time_range_hours" => 6})
      assert_response :success
      assert_match "historical line", tool_text
      refute_match(/last 6h/, tool_text, "an absolute window mislabelled as recent is worse than useless")
      assert_match(at.utc.strftime("%Y-%m-%d"), tool_text)
    end

    # A host breakdown around an incident is minutes long; rounding it to whole
    # hours labelled it "(0h)".
    test "a window shorter than an hour is labelled in minutes" do
      start = 3.hours.ago.beginning_of_minute
      call_tool("get_host_breakdown", {"start_time" => start.iso8601, "end_time" => (start + 26.minutes).iso8601})

      assert_match(/\(26m\)/, tool_text)
      refute_match(/\(0h\)/, tool_text)
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

    test "search_logs surfaces duration and release inline" do
      project = projects(:one)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :error, source: "sentry", body: "shed the request", release: "1.12.0",
        duration_ms: 10.76, payload: {})

      call_tool("search_logs", {"query" => "shed the request"})
      assert_response :success
      # Without these inline, telling "failed fast" from "hung" needs a get_log
      # per line.
      assert_match "dur=11ms", tool_text
      assert_match "release=1.12.0", tool_text
    end

    # Reported from the Booko side 2026-09-12: chasing a Postgres incident, the
    # query that actually worked was `service = 'postgresql' AND server_name =
    # 'pg01'` run by hand against the SQLite file, because search_logs could not
    # express it. pg01's Postgres logs arrive via OTLP and are the signal you
    # want in that situation; both columns are already promoted and populated.
    test "search_logs filters by service" do
      project = projects(:one)
      seed_log_with(project, body: "pg slow query", service: "postgresql")
      seed_log_with(project, body: "rails request done", service: "rails")

      call_tool("search_logs", {"service" => "postgresql"})
      assert_response :success
      assert_match "pg slow query", tool_text
      assert_no_match(/rails request done/, tool_text)
    end

    test "search_logs filters by server_name" do
      project = projects(:one)
      seed_log_with(project, body: "from the db box", server_name: "pg01")
      seed_log_with(project, body: "from the web box", server_name: "web02")

      call_tool("search_logs", {"server_name" => "pg01"})
      assert_response :success
      assert_match "from the db box", tool_text
      assert_no_match(/from the web box/, tool_text)
    end

    test "search_logs combines service and server_name with a full-text query" do
      project = projects(:one)
      want = "checkpoint complete sync"
      seed_log_with(project, body: want, service: "postgresql", server_name: "pg01")
      seed_log_with(project, body: "checkpoint complete sync", service: "postgresql", server_name: "pg02")
      seed_log_with(project, body: "checkpoint complete sync", service: "rails", server_name: "pg01")
      seed_log_with(project, body: "unrelated line", service: "postgresql", server_name: "pg01")

      call_tool("search_logs", {"query" => "checkpoint", "service" => "postgresql", "server_name" => "pg01"})
      assert_response :success
      assert_equal 1, tool_text.scan("checkpoint complete sync").size,
        "expected exactly the one line matching all three filters"
      assert_no_match(/unrelated line/, tool_text)
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

    test "an unknown project is a tool error naming the real projects" do
      call_tool("search_logs", {"query" => "inbound", "project" => "no-such-project"})

      assert_match "Unknown project: no-such-project", tool_error
      assert_match projects(:one).slug, tool_error
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
      assert_match(/Unknown project/, tool_error)
      assert_no_match(/alpha inbound line/, response.body)
    end

    test "an ambiguous project name asks for a slug instead of guessing" do
      duplicate = Project.create!(name: projects(:one).name, slug: "one-duplicate",
        public_key: "dup-key")

      call_tool("search_logs", {"query" => "inbound", "project" => projects(:one).name})

      assert_match "matches 2 projects by name", tool_error
      assert_match duplicate.slug, tool_error
      assert_match projects(:one).slug, tool_error
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

    test "get_transaction shows the span data a non-Rails SDK attached" do
      # End to end: a real sentry-go payload in, the attributes visible to an
      # agent out. Before contexts.trace.data was read at ingest these were
      # discarded, and the client saw a successful ingest either way.
      project = projects(:one)
      Transaction.create_from_sentry_payload!("go-span-data", {
        "transaction" => "PUT /entries/*",
        "start_timestamp" => 1729238400.0,
        "timestamp" => 1729238400.25,
        "contexts" => {
          "trace" => {
            "op" => "http.server",
            "data" => {
              "http.request.method" => "PUT",
              "http.response.status_code" => 201,
              "http.request_content_length" => 4096
            }
          }
        }
      }, project)

      call_tool("get_transaction", {"transaction_id" => "go-span-data"})
      assert_response :success
      assert_match "http.request_content_length", tool_text
      assert_match "4096", tool_text
      # Promoted to the HTTP section rather than repeated as span data.
      assert_match(/Method: PUT/, tool_text)
      assert_match(/Status: 201/, tool_text)
      refute_match "http.request.method", tool_text
    end

    test "get_transaction resolves by trace_id, closing the log to transaction gap" do
      project = projects(:one)
      Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "WorksController#show", duration: 15_000,
        trace_id: "log-handed-me-this")

      call_tool("get_transaction", {"trace_id" => "log-handed-me-this"})
      assert_response :success
      assert_match "WorksController#show", tool_text
    end

    test "get_transaction by trace_id picks the most recent when a trace repeats" do
      project = projects(:one)
      Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: 2.hours.ago, transaction_name: "OldController#show", duration: 10,
        trace_id: "reused-trace")
      Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "NewController#show", duration: 20,
        trace_id: "reused-trace")

      call_tool("get_transaction", {"trace_id" => "reused-trace"})
      assert_response :success
      assert_match "NewController#show", tool_text
      refute_match(/OldController#show/, tool_text)
    end

    # External ids are only indexed behind project_id, so a lookup that leaves
    # it out scans the whole table — on splat-booko a 179s get_event that held
    # the GVL and froze every Puma thread. Asserted on the query plan, since
    # that's the property that matters and the SQL shape is free to change.
    test "id and trace lookups are index searches, never table scans" do
      project = projects(:one)
      event = Event.create!(project: project, event_id: SecureRandom.uuid,
        timestamp: Time.current, payload: nil)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "PlanController#show", duration: 5,
        trace_id: "plan-trace")

      {
        ["get_event", {"event_id" => event.event_id}] => "events",
        ["get_transaction", {"transaction_id" => txn.transaction_id}] => "transactions",
        ["get_transaction", {"trace_id" => "plan-trace"}] => "transactions",
        ["get_transaction", {"trace_id" => "plan-trace", "project" => project.id}] => "transactions"
      }.each do |(tool, args), table|
        plans = query_plans_on(table) { call_tool(tool, args) }

        assert_response :success
        refute JSON.parse(response.body).dig("result", "isError"), "#{tool} #{args} failed: #{tool_text}"
        assert plans.any?, "#{tool} #{args} never queried #{table}"
        plans.each do |plan|
          refute_match(/\bSCAN #{table}\b/, plan, "#{tool} #{args} scans #{table}")
          refute_match(/index_#{table}_on_(project_id_and_)?timestamp/, plan,
            "#{tool} #{args} walks #{table} by timestamp")
        end
      end
    end

    # get_transaction(transaction_id: "62475681") timed out on splat-booko.
    # Finding the transaction is a primary-key lookup; the stall was the
    # "errors in this request" lookup after it, which SQLite planned along
    # [project_id, timestamp] to satisfy its ORDER BY — walking every event
    # the project has, newest first, for a request that threw nothing.
    test "get_transaction looks up the request's errors by trace, not along the project's timeline" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid, timestamp: Time.current,
        transaction_name: "PlanController#show", duration: 5, trace_id: "trace-without-errors")

      plans = query_plans_on("events") do
        call_tool("get_transaction", {"transaction_id" => txn.id.to_s, "project" => project.name})
      end

      refute JSON.parse(response.body).dig("result", "isError"), tool_text
      assert plans.any?, "get_transaction never looked for the request's errors"
      plans.each do |plan|
        refute_match(/\bSCAN events\b/, plan, "scans events")
        refute_match(/index_events_on_(project_id_and_)?timestamp/, plan, "walks events by timestamp")
      end
    end

    test "get_transaction with neither id nor trace_id explains what is needed" do
      # Surfaces as a tool error, same as any other failed lookup — what matters
      # is that the message names both arguments rather than reporting a blank
      # transaction_id miss.
      call_tool("get_transaction", {})
      assert_equal "Supply either transaction_id or trace_id", tool_error
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

    # The two readings need telling apart: many distinct queries is an N+1 over
    # N records (eager-load it), one query repeated is a cache miss (memoise
    # it). Asserted here because this rendering was written against the
    # pre-gem controller and had to be carried across by hand.
    test "get_transaction distinguishes an N+1 from a repeated identical query" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "WorksController#show", duration: 300,
        query_count: 21, has_n_plus_one: true,
        measurements: {"query_analysis" => {"query_patterns" => {
          "SELECT * FROM covers WHERE id = ?" => {"count" => 12, "distinct_count" => 12},
          "SELECT * FROM settings LIMIT ?" => {"count" => 9, "distinct_count" => 1}
        }}})

      call_tool("get_transaction", {"transaction_id" => txn.id})
      assert_response :success

      assert_match "(×12, 12 distinct)", tool_text
      assert_match "(×9, identical — memoisation, not eager loading)", tool_text
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

    # EXPLAIN QUERY PLAN detail for every SELECT … FROM table WHERE … run in the block.
    def query_plans_on(table)
      statements = []
      collect = lambda do |*, payload|
        next unless payload[:sql].match?(/\ASELECT .* FROM "#{table}" WHERE /m)

        binds = payload[:type_casted_binds]
        binds = binds.call if binds.respond_to?(:call)
        statements << [payload[:connection], payload[:sql], binds]
      end
      ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { yield }

      statements.map do |conn, sql, binds|
        conn.select_rows("EXPLAIN QUERY PLAN #{sql}", "EXPLAIN", binds).map(&:last).join(" / ")
      end
    end

    def tool_structured
      JSON.parse(response.body).dig("result", "structuredContent")
    end

    # A tool that fails on its arguments answers with a successful JSON-RPC
    # response carrying isError, not a JSON-RPC error — that's what puts the
    # message in front of the model instead of the transport. See
    # SplatMcpTools#render_error.
    def tool_error
      body = JSON.parse(response.body)
      assert_equal true, body.dig("result", "isError"),
        "expected a tool error, got: #{response.body}"
      body.dig("result", "content", 0, "text").to_s
    end

    def initialize_with(protocol_version)
      post "/mcp",
        params: {
          jsonrpc: "2.0", id: 1, method: "initialize",
          params: {protocolVersion: protocol_version, capabilities: {},
                   clientInfo: {name: "test", version: "1.0"}}
        }.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@token}"}
    end

    def seed_log_with(project, body:, **attrs)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :info, source: "otlp", body: body, payload: {}, **attrs)
    end

    def seed_log_in(project, body)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :error, source: "sentry", body: body, payload: {})
    end

    # Into a completed past hour, so the readers serve it from the rollups.
    def seed_txn(project, name, duration, **attrs)
      Transaction.create!(project: project, transaction_id: SecureRandom.uuid, transaction_name: name,
        timestamp: (Time.current - 2.hours).beginning_of_hour, duration: duration, **attrs)
    end

    # The splat-booko shape: one endpoint name, a little slow traffic in one
    # project and a lot of fast traffic in the other.
    def seed_shared_endpoint
      3.times { seed_txn(projects(:one), "ProductsController#index", 150) }
      10.times { seed_txn(projects(:two), "ProductsController#index", 4) }
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
