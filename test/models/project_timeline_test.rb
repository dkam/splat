require "test_helper"

class ProjectTimelineTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @project = Project.create!(name: "Clock", slug: "clock", public_key: "clock-key")
    @now = Time.utc(2026, 10, 18, 10, 4)
  end

  def issue(title, count: 1, status: :open, first_seen: @now - 30.days)
    Issue.create!(project: @project, fingerprint: SecureRandom.hex(8), title: title, count: count,
      first_seen: first_seen, last_seen: @now, status: status)
  end

  def events(issue, *times)
    Event.insert_all(times.map do |t|
      {event_id: SecureRandom.uuid, project_id: @project.id, issue_id: issue.id, timestamp: t,
       created_at: t, updated_at: t}
    end)
  end

  def timeline(window: "24h") = ProjectTimeline.for(@project, window: window, now: @now)

  test "the 24h window ends with the current hour, which is still filling" do
    tl = timeline
    assert_equal [Time.utc(2026, 10, 17, 11), Time.utc(2026, 10, 18, 11)], [tl.range.begin, tl.range.end]
    assert_equal 24, tl.buckets
    assert tl.partial_last_bucket?
  end

  test "issues with events are rows, busiest first; the rest are only counted" do
    busy = issue("Busy")
    events(busy, @now - 3.hours, @now - 2.hours, @now - 1.hour)
    one = issue("Once")
    events(one, @now - 5.hours)
    issue("Quiet")
    ignored = issue("Muted", status: :ignored)
    events(ignored, @now - 4.hours)

    tl = timeline
    assert_equal [busy, one], tl.issue_rows.map(&:issue)
    assert_equal 3, tl.issue_rows.first.times.size
    assert_equal 1, tl.quiet_open_issue_count
    muted, count, row = tl.ignored_fold
    assert_equal [[ignored], 1], [muted, count]
    assert_equal 1, row.times.size
  end

  # Booko reports a template error and the error it wraps as two issues, with
  # every event in the same second.
  test "two issues firing in the same seconds under the same message are twins, the busier one first" do
    route = "No route matches {action: \"show\", controller: \"products\"}"
    wrapper = issue("#{route} (ActionView::Template::Error)", count: 447)
    cause = issue("#{route} (ActionController::UrlGenerationError)\nDid you mean?", count: 51)
    other = issue("Something else entirely", count: 3)
    stamps = [@now - 6.hours, @now - 2.hours + 7.seconds]
    events(cause, *stamps.map { it + 0.4 })
    events(wrapper, *stamps)
    events(other, *stamps)

    rows = timeline.issue_rows
    assert_equal [wrapper.id, cause.id, other.id], rows.map { it.issue.id }
    assert_equal [nil, wrapper.id, nil], rows.map(&:twin_of)
  end

  test "an issue with more events than can be ticked is drawn as bars" do
    flood = issue("Flood", count: 400)
    events(flood, *Array.new(ProjectTimeline::TICK_LIMIT + 1) { |i| @now - 1.hour + i.seconds })

    row = timeline.issue_rows.sole
    assert_nil row.times
    assert_equal ProjectTimeline::TICK_LIMIT + 1, row.bars.sum
  end

  test "an endpoint gets a p95 line only with enough requests a bucket to have one" do
    hour = @now.beginning_of_hour - 2.hours
    (ProjectTimeline::DENSE_PER_BUCKET * 24).times do |i|
      Transaction.create!(project: @project, transaction_id: "busy-#{i}", transaction_name: "GET /busy", timestamp: hour, duration: 100)
    end
    3.times { |i| Transaction.create!(project: @project, transaction_id: "rare-#{i}", transaction_name: "RareJob", timestamp: hour, duration: 9000) }

    modes = timeline.endpoints.to_h { [it.name, it.mode] }
    assert_equal({"GET /busy" => :line, "RareJob" => :marks}, modes)
  end

  test "a monitor's runs are drawn one by one, and failing monitors come first" do
    nightly = CronMonitor.create!(project: @project, slug: "nightly", state: "ok")
    nightly.check_ins.create!(project_id: @project.id, status: "ok", started_at: @now - 8.hours, finished_at: @now - 7.hours, duration: 3600)
    CronMonitor.create!(project: @project, slug: "silent", state: "missed", last_checkin_at: @now - 40.days)

    rows = timeline.monitor_rows
    assert_equal %w[silent nightly], rows.map { it.monitor.slug }
    assert_equal 1, rows.last.runs.size
    assert_nil rows.last.coverage
  end

  test "a heartbeat with more runs than can be drawn is counted per bucket" do
    beat = CronMonitor.create!(project: @project, slug: "beat", state: "ok")
    CronCheckIn.insert_all(Array.new(ProjectTimeline::TICK_LIMIT + 1) do |i|
      t = @now - 6.hours + i.minutes
      {cron_monitor_id: beat.id, project_id: @project.id, status: "ok", started_at: t, finished_at: t, created_at: t}
    end)

    row = timeline.monitor_rows.sole
    assert_nil row.runs
    assert_equal ProjectTimeline::TICK_LIMIT + 1, row.coverage.values.sum { it["ok"] }
  end

  test "with too little to draw at 24h, the default view opens at 7d and says so" do
    a = issue("Last week")
    events(a, @now - 3.days)

    quiet = ProjectTimeline.for(@project, now: @now)
    assert_equal ["7d", "24h"], [quiet.window.key, quiet.widened_from]
    assert_equal [a], quiet.issue_rows.map(&:issue)

    3.times { |i| events(issue("Today #{i}"), @now - 1.hour) }
    busy = ProjectTimeline.for(@project, now: @now)
    assert_equal ["24h", nil], [busy.window.key, busy.widened_from]
  end

  test "an asked-for window is kept even when it's quiet" do
    assert_equal ["1h", nil], [timeline(window: "1h").window.key, timeline(window: "1h").widened_from]
    assert_equal 5.minutes, timeline(window: "1h").bucket_seconds
  end

  test "the cursor reads out each bucket's counts across the rows" do
    a = issue("A")
    events(a, @now - 2.minutes, @now - 1.minute)
    @project.releases.create!(version: "1.2.3+abcdef1234", first_seen_at: @now - 2.hours, last_seen_at: @now)

    tl = timeline
    last = tl.cursor_buckets.last
    assert_equal [Time.utc(2026, 10, 18, 10).to_i, 2, [["##{a.id}", 2]]], last.values_at(:t, :events, :issues)
    assert_equal ["1.2.3+abcdef1234"], tl.deploys.map(&:version)
  end
end
