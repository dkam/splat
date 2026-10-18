require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured, so these hit the real controller.
  setup do
    @project = projects(:one)
    # The index and show actions cache their aggregate bundles, and the test
    # env uses a memory store that outlives a single test — without this, the
    # first test to load a page decides what every later one sees.
    Rails.cache.clear
  end

  test "show draws a logs row that links to the logs" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "x", payload: {})

    get project_url(@project.slug, window: "24h")
    assert_response :success
    assert_select "a[href=?]", project_logs_path(@project.slug), text: "Logs"
  end

  # With no traffic there's no response time to show. It used to read as a
  # healthy 0ms instead of N/A.
  test "show gives N/A, not zero, for latency with no traffic" do
    get project_url(@project.slug)

    assert_response :success
    refute_match(/>\s*0ms\s*</, response.body)
    assert_match(/N\/A <span[^>]*>p50/, response.body)
  end

  test "show labels an issue's row by its message, without the error_highlight snippet" do
    message = "undefined local variable or method 'job' for main\n\n    job.perform\n    ^^^"
    Event.create_from_sentry_payload!(
      "evt-highlighted",
      {"exception" => {"values" => [{"type" => "NameError", "value" => message}]}, "timestamp" => Time.current.iso8601},
      @project
    )

    get project_url(@project.slug, window: "24h")
    assert_response :success
    assert_select "a", text: "undefined local variable or method 'job' for main"
    assert_select "a", text: /\^\^\^/, count: 0
  end

  test "show offers resolve, resolve in the next release and ignore on an issue with events" do
    event = Event.create_from_sentry_payload!("evt-triage",
      {"message" => "Triage me", "release" => "2.0.0", "timestamp" => Time.current.iso8601}, @project)
    issue = event.issue

    get project_url(@project.slug, window: "24h")
    assert_response :success
    assert_select "form[action=?]", resolve_project_issue_path(@project.slug, issue)
    assert_select "form[action=?]", resolve_in_next_release_project_issue_path(@project.slug, issue)
    assert_select "form[action=?]", ignore_project_issue_path(@project.slug, issue)
    assert_select "a form", count: 0
  end

  test "show leaves resolve in the next release off until a release has been seen" do
    issue = Event.create_from_sentry_payload!("evt-norelease",
      {"message" => "No release", "timestamp" => Time.current.iso8601}, @project).issue

    get project_url(@project.slug, window: "24h")
    assert_select "form[action=?]", resolve_project_issue_path(@project.slug, issue)
    assert_select "form[action=?]", resolve_in_next_release_project_issue_path(@project.slug, issue), count: 0
  end

  test "show marks a deploy in the window with its release" do
    @project.releases.create!(version: "19.12.3+5a6f4862b90cc623eaa52a546b30453b52f36a13",
      first_seen_at: 2.hours.ago, last_seen_at: 1.hour.ago)

    get project_url(@project.slug, window: "24h")
    assert_response :success
    assert_select "span", text: "▾ 19.12.3 · 5a6f486"
  end

  test "show opens a quiet project at 7d, says so, and keeps a window it's asked for" do
    get project_url(@project.slug)
    assert_select "nav[aria-label=Window] a[aria-current=page]", text: "7d"
    assert_match "the last 24h had too little to draw", response.body

    get project_url(@project.slug, window: "1h")
    assert_select "nav[aria-label=Window] a[aria-current=page]", text: "1h"
    refute_match "too little to draw", response.body
  end

  test "show draws every window" do
    ProjectTimeline::WINDOWS.each_key do |key|
      get project_url(@project.slug, window: key)
      assert_response :success, key
    end
  end

  test "show offers a DSN pointing at the requested authority when SPLAT_HOST is unset" do
    # Without .env (a fresh clone), a server on a non-default port used to hand
    # out a hardcoded localhost:3000 DSN.
    original = ENV.delete("SPLAT_HOST")

    get project_url(@project.slug), headers: {"HOST" => "localhost:3031"}

    assert_response :success
    assert_select "[data-clipboard-text-value=?]", "http://#{@project.public_key}@localhost:3031/#{@project.slug}"
  ensure
    ENV["SPLAT_HOST"] = original
  end

  test "show prefers SPLAT_HOST over the requested authority" do
    # The externally reachable host can differ from the one being browsed.
    original = ENV["SPLAT_HOST"]
    ENV["SPLAT_HOST"] = "splat.example.com"

    get project_url(@project.slug), headers: {"HOST" => "localhost:3031"}

    assert_response :success
    assert_select "[data-clipboard-text-value=?]", "https://#{@project.public_key}@splat.example.com/#{@project.slug}"
  ensure
    ENV["SPLAT_HOST"] = original
  end

  test "index lists projects in their saved card order" do
    projects(:one).update!(position: 2)
    projects(:two).update!(position: 1)

    get root_url

    assert_response :success
    assert_operator response.body.index("Project Two"), :<, response.body.index("Project One")
  end

  test "reorder persists the dragged card order" do
    patch reorder_projects_url, params: {slugs: ["project-two", "project-one"]}, as: :json

    assert_response :success
    assert_equal ["project-two", "project-one"], Project.ordered.pluck(:slug)
  end

  test "reorder ignores slugs that no longer exist" do
    patch reorder_projects_url, params: {slugs: ["project-two", "gone", "project-one"]}, as: :json

    assert_response :success
    assert_equal ["project-two", "project-one"], Project.ordered.pluck(:slug)
  end

  test "reorder appends projects missing from the submitted order" do
    # A card added by someone else between page load and drop must not be
    # dropped from the ordering just because this client never saw it.
    third = Project.create!(name: "Project Three", public_key: "test-public-key-three")

    patch reorder_projects_url, params: {slugs: ["project-two", "project-one"]}, as: :json

    assert_response :success
    assert_equal ["project-two", "project-one", third.slug], Project.ordered.pluck(:slug)
  end

  test "index cards carry the drag handle and no slug subtitle" do
    get root_url

    assert_response :success
    assert_select "[data-sortable-target='item'][data-slug=?]", @project.slug
    assert_select "[data-sortable-target='handle']"
    assert_no_match "/#{@project.slug}<", response.body
  end

  test "index cards show monitor health, new issues and 24h performance" do
    CronMonitor.create!(project: @project, slug: "nightly", state: "missed")
    Issue.create!(project_id: @project.id, fingerprint: "fresh", title: "Fresh boom",
      first_seen: 1.hour.ago, last_seen: 1.hour.ago, status: :open)
    Transaction.create!(project_id: @project.id, transaction_id: SecureRandom.uuid_v7,
      timestamp: 30.minutes.ago, transaction_name: "PagesController#show",
      duration: 120, http_status: "200")

    get root_url

    assert_response :success
    assert_match "1 monitor failing", response.body
    assert_select "div", text: "new (24h)"
    assert_match "req", response.body
  end

  test "update saves the source link template" do
    template = "https://git.example/booko/booko/src/commit/{sha}/{path}#L{line}"

    patch project_url(@project.slug), params: {project: {source_url_template: template}}

    assert_redirected_to project_path(@project.slug)
    assert_equal template, @project.reload.source_url_template
  end

  test "edit offers the source link template" do
    get edit_project_url(@project.slug)

    assert_select "input[name=?]", "project[source_url_template]"
  end
end
