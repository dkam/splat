# frozen_string_literal: true

require "test_helper"

class IssuesTimelineTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Issues clock", slug: "issues-clock", public_key: "issues-clock-key")
    @now = Time.utc(2026, 10, 18, 10, 4)
  end

  def issue(title, status: :open, first_seen: @now - 30.days, count: 1)
    Issue.create!(project: @project, fingerprint: SecureRandom.hex(8), title: title, count: count,
      first_seen: first_seen, last_seen: @now, status: status)
  end

  def events(issue, *times, environment: nil)
    Event.insert_all(times.map do |t|
      {event_id: SecureRandom.uuid, project_id: @project.id, issue_id: issue.id, timestamp: t,
       environment: environment, created_at: t, updated_at: t}
    end)
  end

  def timeline(**options) = IssuesTimeline.new(@project, window: "24h", now: @now, **options)

  test "keeps the project page's clock, so the two pages' buckets line up" do
    project = ProjectTimeline.new(@project, ProjectTimeline::WINDOWS.fetch("24h"), now: @now)

    assert_equal project.range, timeline.range
    assert_equal [3600, 24], [timeline.bucket_seconds, timeline.buckets]
  end

  test "a bucket another page opened is cut into the buckets of the nearest window" do
    from = Time.utc(2026, 10, 18, 6)
    tl = IssuesTimeline.new(@project, range: from...(from + 1.hour), now: @now)

    assert_equal from...(from + 1.hour), tl.range
    assert_equal [300, 12], [tl.bucket_seconds, tl.buckets]
  end

  # The Events row is the tab's: resolving an issue takes its events out of
  # the open tab's row and puts them in the resolved tab's.
  test "the Events row and the counts are the tab's issues' alone" do
    open = issue("Open")
    events(open, @now - 3.hours, @now - 3.hours + 5.minutes, @now - 1.hour)
    fixed = issue("Fixed", status: :resolved)
    events(fixed, @now - 2.hours)

    tl = timeline
    assert_equal 3, tl.events_per_bucket.sum
    assert_equal({open.id => 3}, tl.counts)
    assert_equal 2, tl.events_per_bucket[tl.buckets - 4]

    assert_equal({fixed.id => 1}, timeline(status: "resolved").counts)
  end

  test "busiest lists the issues with events in the window, most first" do
    once = issue("Once")
    events(once, @now - 5.hours)
    busy = issue("Busy")
    events(busy, @now - 3.hours, @now - 2.hours)
    issue("Quiet")

    assert_equal [busy.id, once.id], timeline.busiest_ids
  end

  test "an issue with few events in the window is ticked, one with many barred, a quiet one neither" do
    few = issue("Few")
    events(few, @now - 3.hours, @now - 1.hour)
    many = issue("Many")
    events(many, *Array.new(ProjectTimeline::TICK_LIMIT + 1) { @now - 2.hours })
    quiet = issue("Quiet")

    rows = timeline.rows([few, many, quiet]).index_by { it.issue }

    assert_equal [@now - 3.hours, @now - 1.hour], rows[few].times
    assert_nil rows[few].bars
    assert_nil rows[many].times
    assert_equal ProjectTimeline::TICK_LIMIT + 1, rows[many].bars.sum
    assert_equal [0, nil, nil], [rows[quiet].in_window, rows[quiet].times, rows[quiet].bars]
  end

  test "new issues are those of the tab first seen in the window" do
    issue("Fresh", first_seen: @now - 2.hours)
    issue("Old")
    issue("Fresh but ignored", status: :ignored, first_seen: @now - 1.hour)

    tl = timeline
    assert_equal [@now - 2.hours], tl.first_seen_times
    assert_equal 1, tl.first_seen_per_bucket[tl.buckets - 3]
  end

  test "an environment narrows the events to that environment's" do
    both = issue("Both")
    IssueFacet.harvest!(project_id: @project.id, issue_id: both.id, values: {environment: "production"})
    IssueFacet.harvest!(project_id: @project.id, issue_id: both.id, values: {environment: "staging"})
    events(both, @now - 2.hours, environment: "production")
    events(both, @now - 1.hour, environment: "staging")

    assert_equal({both.id => 1}, timeline(environment: "staging").counts)
  end

  # The busiest in a bucket from the whole tab, not just the page drawn.
  test "the cursor reads out a bucket's events, its busiest issues and its new ones" do
    a = issue("A", first_seen: @now - 2.hours - 10.minutes)
    events(a, @now - 2.hours - 10.minutes, @now - 2.hours - 5.minutes)
    b = issue("B")
    events(b, @now - 2.hours - 30.minutes)

    bucket = timeline.cursor_buckets[-4]
    assert_equal [["3 events: ##{a.id} ×2 ##{b.id} ×1"], ["1 new", "text-emerald-700 dark:text-emerald-300"]], bucket[:facts]
  end
end
