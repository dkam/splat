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

  test "show renders with the logs quick-link card" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "x", payload: {})

    get project_url(@project.slug)
    assert_response :success
    assert_match "Logs (24h)", response.body
    assert_select "a[href=?]", project_logs_path(@project.slug)
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
end
