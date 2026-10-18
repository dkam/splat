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
  # Ruby's error_highlight appends the offending line and a caret row to the
  # exception message.
  HIGHLIGHTED = "undefined local variable or method 'job' for main

        job.perform
        ^^^"
  MESSAGE = "undefined local variable or method 'job' for main"

  # `rescue Net::ReadTimeout; raise PaymentFailed`, as sentry-ruby sends it:
  # root cause first, the raised exception last.
  CHAINED = {
    "exception" => {"values" => [
      {"type" => "Net::ReadTimeout", "value" => "Net::ReadTimeout with #<TCPSocket:(closed)>",
       "stacktrace" => {"frames" => [{"filename" => "net/protocol.rb", "lineno" => 229, "function" => "rbuf_fill"}]}},
      {"type" => "PaymentFailed", "value" => "gateway timed out",
       "stacktrace" => {"frames" => [{"filename" => "app/models/payment.rb", "lineno" => 42, "function" => "charge", "in_app" => true}]}}
    ]},
    "timestamp" => "2026-10-11T08:00:00Z"
  }.freeze

  # The wrapper's backtrace is its cause's, which sentry-ruby sends only once,
  # on the cause.
  TEMPLATE_ERROR = {
    "exception" => {"values" => [
      {"type" => "NoMethodError", "value" => "undefined method 'title' for nil",
       "stacktrace" => {"frames" => [{"filename" => "app/views/books/show.html.erb", "lineno" => 12, "function" => "_app_views_show", "in_app" => true}]}},
      {"type" => "ActionView::Template::Error", "value" => "undefined method 'title' for nil"}
    ]},
    "timestamp" => "2026-10-11T08:00:00Z"
  }.freeze

  test "show heads the page with the message and sets an error_highlight snippet below it as code" do
    event = Event.create_from_sentry_payload!(
      "evt-highlighted",
      {"exception" => {"values" => [{"type" => "NameError", "value" => HIGHLIGHTED}]},
       "timestamp" => "2026-07-17T08:00:00Z"},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "h1", text: MESSAGE
    # The shared indent goes; the caret keeps its column under the code.
    assert_select "pre#event-message-detail", text: "job.perform
^^^"
  end

  test "show sets the exception value's error_highlight snippet below its message as code" do
    event = Event.create_from_sentry_payload!(
      "evt-highlighted-value",
      {"exception" => {"values" => [{"type" => "NameError", "value" => HIGHLIGHTED}]},
       "timestamp" => "2026-07-17T08:00:00Z"},
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "p", text: MESSAGE
    assert_select "pre#exception-value-detail", text: "job.perform\n^^^"
  end

  test "show lists what the exception was caused by, with each cause's stack trace" do
    event = Event.create_from_sentry_payload!("evt-chained", CHAINED, @project)

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "#caused-by-1 h2", text: /Caused by\s+Net::ReadTimeout/
    assert_select "#caused-by-1", text: /Net::ReadTimeout with #<TCPSocket:\(closed\)>/
    assert_select "#caused-by-1 .stack-frame", text: /net\/protocol\.rb/
    # The root cause is linked from the top of the page, not only at the bottom.
    assert_select "a[href='#caused-by-1']", text: /Net::ReadTimeout/
  end

  test "show doesn't repeat a stack trace the cause shares with the exception above it" do
    event = Event.create_from_sentry_payload!("evt-template", TEMPLATE_ERROR, @project)

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select ".stack-frame", text: /app\/views\/books\/show\.html\.erb/, count: 1
    assert_select "#caused-by-1", text: /Same stack trace as above/
  end

  test "show sets no snippet under a one-line message" do
    event = Event.create_from_sentry_payload!(
      "evt-one-line", {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z"}, @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "h1", text: "boom"
    assert_select "#event-message-detail", count: 0
  end

  test "show links in-app frames to their line in the repository at the release's commit" do
    sha = "e59f6680a82f15d8f82131f9c4c417223f31a153"
    @project.update!(source_url_template: "https://git.example/booko/booko/src/commit/{sha}/{path}#L{line}")
    event = Event.create_from_sentry_payload!(
      "evt-source-links",
      CHAINED.merge("release" => "19.11.0+#{sha}"),
      @project
    )

    get project_event_url(@project.slug, event)
    assert_response :success
    assert_select "a[href=?]", "https://git.example/booko/booko/src/commit/#{sha}/app/models/payment.rb#L42"
    # net/protocol.rb is Ruby's, not the project's.
    assert_select "a[href^='https://git.example/']", count: 1
  end

  # What a click on the project timeline's Events row opens.
  test "index lists a window's events, newest first, with a count for each issue" do
    from = Time.utc(2026, 10, 18, 10)
    to = from + 1.hour
    before = event_at("Before the window", from - 1.minute)
    closed = [event_at("Tuber closed", from + 42.minutes), event_at("Tuber closed", from + 43.minutes)]
    eof = event_at("end of file reached", from + 50.minutes)
    after = event_at("After the window", to + 1.minute)

    get project_events_url(@project.slug, from: from.iso8601, to: to.iso8601)
    assert_response :success
    [*closed, eof].each { assert_select "a[href=?]", project_event_path(@project.slug, it) }
    [before, after].each { assert_select "a[href=?]", project_event_path(@project.slug, it), count: 0 }
    assert_operator response.body.index(project_event_path(@project.slug, eof)), :<, response.body.index(project_event_path(@project.slug, closed.last))

    assert_select "a[href=?]", project_events_path(@project.slug, issue_id: closed.first.issue_id, from: from.iso8601, to: to.iso8601), text: /×2/
    assert_select "a[href=?]", project_events_path(@project.slug, from: (from - 1.hour).iso8601, to: from.iso8601)
    assert_select "a[href=?]", project_events_path(@project.slug, from: to.iso8601, to: (to + 1.hour).iso8601)
  end

  test "index narrows to one issue, or to the issues in a status" do
    from = 1.hour.ago.utc.beginning_of_minute
    kept = event_at("Kept", from + 1.minute)
    resolved = event_at("Fixed already", from + 2.minutes)
    resolved.issue.resolved!

    get project_events_url(@project.slug, issue_id: kept.issue_id, from: from.iso8601, to: Time.current.iso8601)
    assert_select "a[href=?]", project_event_path(@project.slug, kept)
    assert_select "a[href=?]", project_event_path(@project.slug, resolved), count: 0

    get project_events_url(@project.slug, status: "resolved", from: from.iso8601, to: Time.current.iso8601)
    assert_select "a[href=?]", project_event_path(@project.slug, resolved)
    assert_select "a[href=?]", project_event_path(@project.slug, kept), count: 0
  end

  test "index without a usable window shows the last 24 hours" do
    old = event_at("Two days ago", 2.days.ago)
    recent = event_at("An hour ago", 1.hour.ago)

    get project_events_url(@project.slug, from: "yesterday-ish", to: "")
    assert_response :success
    assert_select "a[href=?]", project_event_path(@project.slug, recent)
    assert_select "a[href=?]", project_event_path(@project.slug, old), count: 0
  end

  private

  def event_at(message, at)
    Event.create_from_sentry_payload!(SecureRandom.hex(16), {"message" => message, "timestamp" => at.utc.iso8601}, @project)
  end
end
