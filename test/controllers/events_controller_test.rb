require "test_helper"

class EventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
  end

  test "show links to the transaction the error was thrown in" do
    trace = "abc123abc123abc123abc123abc12300"
    txn = @project.transactions.create!(
      transaction_id: "txn-linked", transaction_name: "BooksController#show",
      timestamp: Time.current, duration: 240, trace_id: trace
    )
    event = Event.create_from_sentry_payload!(
      "evt-linked",
      {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "a[href=?]", project_transaction_path(@project.slug, txn)
  end

  test "show links to the trace's logs when any exist" do
    trace = "def456def456def456def456def45600"
    Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, trace_id: trace,
      level: :error, source: "sentry", body: "kaboom", timestamp: Time.current
    )
    event = Event.create_from_sentry_payload!(
      "evt-with-logs",
      {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "a[href=?]", project_logs_path(@project.slug, trace_id: trace)
  end

  test "show renders without trace links for an untraced event" do
    event = Event.create_from_sentry_payload!(
      "evt-untraced",
      {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z"},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "a", text: /View transaction/, count: 0
    assert_select "a", text: /for this trace/, count: 0
  end

  test "show breadcrumbs keep the issue's ancestors instead of a lone back link" do
    event = Event.create_from_sentry_payload!(
      "evt-breadcrumb",
      {"exception" => {"values" => [{"type" => "NoMethodError", "value" => "boom"}]},
       "timestamp" => "2026-07-17T08:00:00Z"},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "nav[aria-label=Breadcrumb] li", 4
    assert_select "nav[aria-label=Breadcrumb] a[href=?]", project_issues_path(@project.slug)
    assert_select "nav[aria-label=Breadcrumb] a[href=?]", project_issue_path(@project.slug, event.issue)
    assert_select "nav[aria-label=Breadcrumb] [aria-current=page]", "Event ##{event.id}"
  end
end
