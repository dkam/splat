# frozen_string_literal: true

require "test_helper"

class MonitorsTimelineTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Monitors clock", slug: "monitors-clock", public_key: "monitors-clock-key")
    @now = Time.utc(2026, 10, 18, 10, 4)
  end

  def monitor(slug, state: "ok", created_at: @now - 60.days, **schedule)
    CronMonitor.create!(project: @project, slug: slug, state: state, created_at: created_at, **schedule)
  end

  def daily(slug, **options) = monitor(slug, schedule_type: "crontab", schedule_value: "0 3 * * *", checkin_margin: 60, **options)

  def hourly(slug, **options) = monitor(slug, schedule_type: "interval", schedule_value: "1", schedule_unit: "hour", checkin_margin: 15, **options)

  def runs(monitor, *starts, status: "ok", duration: nil)
    CronCheckIn.insert_all(starts.map do |at|
      {cron_monitor_id: monitor.id, project_id: @project.id, status: status, started_at: at,
       finished_at: (at + duration.to_f unless status == "in_progress"), duration: duration, created_at: at}
    end)
  end

  def timeline(window = "7d", now: @now) = MonitorsTimeline.new(@project, window: window, now: now)

  def row(slug, tl = timeline) = tl.rows.find { it.monitor.slug == slug }

  test "a crontab's times are kept by a run within its margin, and missed without one" do
    nightly = daily("nightly")
    runs(nightly, Time.utc(2026, 10, 13, 3, 0, 30), Time.utc(2026, 10, 14, 2, 59, 30),
      Time.utc(2026, 10, 16, 3, 50), Time.utc(2026, 10, 17, 4, 30), Time.utc(2026, 10, 18, 3))

    slots = row("nightly").slots.to_h { [it.at.day, it.kept] }
    # The 12th's margin ran out before the first check-in kept, on the 13th.
    assert_equal({12 => nil, 13 => true, 14 => true, 15 => false, 16 => true, 17 => false, 18 => true}, slots)
    assert_equal [6, 4], [row("nightly").due, row("nightly").kept]
  end

  test "a crontab's time whose margin hasn't run out isn't judged yet" do
    nightly = daily("nightly")
    runs(nightly, Time.utc(2026, 10, 17, 3))

    tl = timeline(now: Time.utc(2026, 10, 18, 3, 30))
    assert_equal [true, nil], row("nightly", tl).slots.last(2).map(&:kept)
  end

  # Every hour on the half hour, but for 15:30 and 16:30 on the 17th: three
  # hours from one to the next, so two missed.
  test "an interval's silence past its interval and margin is a gap, each interval past the margin one missed" do
    beat = hourly("hourly")
    starts = (0..33).map { Time.utc(2026, 10, 17, 0, 30) + it.hours }
    runs(beat, *(starts - [Time.utc(2026, 10, 17, 15, 30), Time.utc(2026, 10, 17, 16, 30)]))

    r = row("hourly", timeline("24h"))
    assert_equal [MonitorsTimeline::Gap.new(from: Time.utc(2026, 10, 17, 15, 30), to: Time.utc(2026, 10, 17, 17, 30))], r.gaps
    assert_equal [23, 21], [r.due, r.kept]
  end

  test "an interval monitor silent since the window opened misses every interval of it" do
    other = hourly("other")
    runs(other, @now - 3.days)
    hourly("silent", state: "missed", created_at: @now - 3.days)

    r = row("silent", timeline("24h"))
    assert_equal [23, 0], [r.due, r.kept]
    assert_equal 1, r.gaps.size
  end

  test "failing first, then by how often each runs, and those long gone quiet at the foot" do
    runs(hourly("erroring", state: "error"), @now - 1.hour, status: "error")
    monitor("beat", schedule_type: "interval", schedule_value: "1", schedule_unit: "minute")
    daily("nightly")
    monitor("weekly", schedule_type: "crontab", schedule_value: "0 3 * * 6")
    daily("late", state: "missed", last_checkin_at: @now - 2.days)
    daily("retired", state: "missed", last_checkin_at: @now - 40.days)
    monitor("unscheduled")

    groups = timeline.groups.to_h { [it.key, it.rows.map { it.monitor.slug }] }
    assert_equal({"failing" => %w[erroring late], "minutes" => %w[beat], "days" => %w[nightly],
      "weeks" => %w[weekly], "unscheduled" => %w[unscheduled], "quiet" => %w[retired]}, groups)
  end

  test "a run still marked in progress with one going since is lost; the one going now isn't" do
    job = hourly("job", in_progress_since: @now - 5.minutes)
    runs(job, @now - 5.hours, status: "in_progress")
    runs(job, @now - 4.hours, @now - 3.hours, duration: 60)
    runs(job, @now - 2.hours, duration: 120)
    runs(job, @now - 5.minutes, status: "in_progress")

    r = row("job")
    assert_equal [5, 1], [r.runs_in_window, r.lost]
    assert_equal [80.0, 120.0], [r.avg, r.max]
  end

  test "the cursor names a bucket's misses and long runs, but not a monitor gone quiet" do
    nightly = daily("nightly")
    runs(nightly, Time.utc(2026, 10, 16, 3), duration: 5000)
    runs(nightly, Time.utc(2026, 10, 18, 3), duration: 5)
    daily("retired", state: "missed", last_checkin_at: @now - 40.days)

    tl = timeline
    at = ->(time) { tl.cursor_buckets.find { it[:t] <= time.to_i && time.to_i < it[:t] + tl.bucket_seconds }[:facts] }
    assert_equal [["nightly 1h 23m"]], at.call(Time.utc(2026, 10, 16, 3))
    assert_equal [["nightly missed", MonitorsTimeline::RED]], at.call(Time.utc(2026, 10, 17, 3))
    assert_equal [["nothing missed", MonitorsTimeline::GREEN]], at.call(Time.utc(2026, 10, 18, 3))
  end
end
