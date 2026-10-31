require "test_helper"

class LogsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured, so these hit the real controller.
  setup do
    @project = projects(:one)
    @log = Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :error, source: "sentry", body: "controller test log",
      trace_id: "ctrl-trace", logger_name: "rails", environment: "production",
      payload: {"body" => "controller test log", "attributes" => {"k" => "v"}}
    )
  end

  test "index renders the stream" do
    get project_logs_url(@project.slug)
    assert_response :success
    assert_match "controller test log", response.body
  end

  test "index filters by level" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :debug, source: "sentry", body: "noisy debug line", payload: {})

    get project_logs_url(@project.slug, level: "error")
    assert_response :success
    assert_match "controller test log", response.body
    refute_match "noisy debug line", response.body
  end

  test "index filters by release" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :error, source: "sentry", body: "line from the old deploy", release: "1.11.1", payload: {})
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :error, source: "sentry", body: "line from the new deploy", release: "1.12.0", payload: {})

    get project_logs_url(@project.slug, release: "1.12.0")
    assert_response :success
    assert_match "line from the new deploy", response.body
    refute_match "line from the old deploy", response.body
  end

  test "index offers a release dropdown once more than one release is known" do
    Facet.where(project_id: @project.id, stream: "log", name: "release").delete_all
    Facet.reset_throttle!
    Facet.harvest!(project_id: @project.id, stream: :log, values: {release: %w[1.11.1 1.12.0]})

    get project_logs_url(@project.slug)
    assert_response :success
    # Newest deploy first — the dropdown is ordered by the controller, not by
    # the facet table's lexical sort.
    assert_match(/1\.12\.0.*1\.11\.1/m, response.body)
  end

  test "index filters by trace_id" do
    get project_logs_url(@project.slug, trace_id: "ctrl-trace")
    assert_response :success
    assert_match "controller test log", response.body
  end

  test "index paginates with countless prev/next nav across pages" do
    # One page holds 50; create enough to force a second page.
    60.times do |i|
      Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: i.seconds.ago,
        level: :info, source: "sentry", body: "page fill #{i}", payload: {})
    end

    # Page 1: a Next link, Prev disabled.
    get project_logs_url(@project.slug)
    assert_response :success
    assert_match "Next ›", response.body
    assert_select "a[rel=next]", 1
    assert_select "span[aria-disabled=true]", text: /Prev/

    # Page 2: a working Prev link back.
    get project_logs_url(@project.slug, page: 2)
    assert_response :success
    assert_select "a[rel=prev]", 1
  end

  # Logs are a file per ingest day (ADR 0005): a page can take rows from
  # several, merged by timestamp.
  test "index pages across day files, newest first" do
    30.times do |i|
      Log.create!(project_id: @project.id, log_id: log_id_at(1.day.ago), timestamp: 1.day.ago - i.seconds,
        level: :info, source: "sentry", body: "yesterday #{i}", payload: {})
      Log.create!(project_id: @project.id, log_id: log_id_at(Time.current), timestamp: (i + 1).seconds.ago,
        level: :info, source: "sentry", body: "today #{i}", payload: {})
    end

    get project_logs_url(@project.slug)
    assert_select "a[href^=?]", project_logs_path(@project.slug) + "/", count: 50
    assert_match "yesterday 18", response.body
    refute_match "yesterday 19", response.body

    get project_logs_url(@project.slug, page: 2)
    assert_select "a[href^=?]", project_logs_path(@project.slug) + "/", count: 11
    assert_match "yesterday 29", response.body
  end

  test "show finds a log by log_id in an older day file" do
    old = Log.create!(project_id: @project.id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, source: "sentry", body: "three days back", payload: {})

    get project_log_url(@project.slug, old.log_id)
    assert_response :success
    assert_match "three days back", response.body
  end

  test "show is a 404 for another project's log" do
    other = Log.create!(project_id: projects(:two).id, timestamp: Time.current,
      level: :info, source: "sentry", body: "not yours", payload: {})

    get project_log_url(@project.slug, other.log_id)
    assert_response :not_found
  end

  test "show renders a single log with attributes" do
    get project_log_url(@project.slug, @log)
    assert_response :success
    assert_match "controller test log", response.body
    assert_match "Attributes", response.body
  end

  # What a click on the project timeline's Logs row opens.
  test "index narrows to a window, and keeps it through the other filters" do
    from = 2.hours.ago.utc.beginning_of_hour
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: from - 1.minute,
      level: :info, source: "sentry", body: "a line before the window", payload: {})
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: from + 5.minutes,
      level: :info, source: "sentry", body: "a line inside the window", payload: {})

    get project_logs_url(@project.slug, from: from.iso8601, to: (from + 1.hour).iso8601)
    assert_response :success
    assert_match "a line inside the window", response.body
    refute_match "a line before the window", response.body
    refute_match "controller test log", response.body
    assert_select "input[type=hidden][name=from][value=?]", from.iso8601
    assert_select "input[type=hidden][name=to][value=?]", (from + 1.hour).iso8601
  end

  # The "any time" link is this page with ?from=&to= dropped. Built with
  # url_for(query), a ?host= in the query became the link's host.
  test "index's links back out of a window stay on this site" do
    from = 2.hours.ago.utc.beginning_of_hour
    hostile = {host: "evil.example", script_name: "//evil.example", protocol: "javascript"}
    get project_logs_path(@project.slug), params: {from: from.iso8601, to: (from + 1.hour).iso8601, **hostile}
    assert_response :success
    assert_select "a[href^=?]", "#{project_logs_path(@project.slug)}?", text: "any time"
    refute_match %r{href="[^"]*//evil\.example}, response.body
    refute_match %r{href="javascript:}, response.body
  end
end

# A link from before day files carries the log's numeric id, which only the
# legacy database can still answer. Reading it opens a pool the test drops
# afterwards, which a test transaction can't survive, so no transaction.
class LogsControllerLegacyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @project = projects(:one)
    @dir = Pathname(Dir.mktmpdir("legacy"))
    Logs::DayFiles.legacy_path = build_legacy_logs(@dir.join("logs.sqlite3"), rows: [
      {project_id: @project.id, timestamp: 2.days.ago, body: "a log from an old link"}
    ])
  end

  teardown do
    Logs::DayFiles.legacy_path = nil
    FileUtils.rm_rf(@dir)
  end

  test "show answers a numeric id from the legacy database" do
    get project_log_url(@project.slug, 1)
    assert_response :success
    assert_match "a log from an old link", response.body
  end
end
