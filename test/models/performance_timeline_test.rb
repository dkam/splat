# frozen_string_literal: true

require "test_helper"

class PerformanceTimelineTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @project = Project.create!(name: "Perf", slug: "perf-timeline", public_key: "perf-timeline-key")
    @now = Time.utc(2026, 10, 19, 9, 20)
    Facet.reset_throttle!
  end

  def txn(name, at:, duration:, op: "http.server")
    TransactionKind.harvest!(project_id: @project.id, transaction_name: name, op: op)
    Transaction.create!(project: @project, transaction_id: SecureRandom.uuid, transaction_name: name,
      op: op, timestamp: at, duration: duration)
  end

  test "keeps the project page's clock, so the two pages' buckets line up" do
    timeline = PerformanceTimeline.new(@project, window: "24h", now: @now)
    project = ProjectTimeline.new(@project, ProjectTimeline::WINDOWS.fetch("24h"), now: @now)

    assert_equal project.range, timeline.range
    assert_equal [3600, 24], [timeline.bucket_seconds, timeline.buckets]
    refute timeline.raw?
  end

  # A click on one of the project page's 15-minute buckets opens this page for
  # it: a quarter of an hour the hourly rollups can't answer, so raw rows.
  test "a window another page opened is cut into the buckets of the nearest window" do
    from = Time.utc(2026, 10, 19, 6, 15)
    timeline = PerformanceTimeline.new(@project, range: from...(from + 15.minutes), now: @now)

    assert_equal from...(from + 15.minutes), timeline.range
    assert_equal [75, 12], [timeline.bucket_seconds, timeline.buckets]
    assert timeline.raw?
  end

  # Two days into the 7d window's 42 buckets is 4,114s a bucket, which the
  # hourly rollups can't tile: the series would come back with fewer buckets
  # than the axis has.
  test "a window typed by hand is widened to buckets of whole hours" do
    to = Time.utc(2026, 10, 19, 0)
    timeline = PerformanceTimeline.new(@project, range: (to - 2.days)...to, kind: "web", now: @now)

    assert_equal 7200, timeline.bucket_seconds
    assert_equal (to - 84.hours)...to, timeline.range
    assert_equal 42, timeline.signal("web").throughput.size
  end

  test "each kind is drawn and counted apart, and the cursor reads out each" do
    hour = Time.utc(2026, 10, 19, 7)
    3.times { txn("ProductsController#show", at: hour + 5.minutes, duration: 100) }
    txn("CoverDownloadJob", at: hour + 10.minutes, duration: 5000, op: "queue.process")

    timeline = PerformanceTimeline.new(@project, window: "24h", now: @now)

    assert_equal %w[web job], timeline.kinds
    assert_equal({web: 3, job: 1}, {web: timeline.totals["web"][:count], job: timeline.totals["job"][:count]})
    assert_equal 3, timeline.signal("web").throughput.sum
    assert_in_delta 5000, timeline.signal("job").percentiles[:p50], 50
    assert_equal ["CoverDownloadJob"], timeline.endpoints("job").map(&:name)

    bucket = timeline.cursor_buckets.find { it[:t] == hour.to_i }
    assert_equal ["requests 3 · p95 100ms", "jobs 1 · p95 5.0s"], bucket[:facts].map(&:first).first(2)
  end

  test "one kind's page draws that kind alone, and counts the others" do
    txn("ProductsController#show", at: Time.utc(2026, 10, 19, 7, 5), duration: 100)
    txn("CoverDownloadJob", at: Time.utc(2026, 10, 19, 7, 10), duration: 5000, op: "queue.process")

    timeline = PerformanceTimeline.new(@project, window: "24h", kind: "job", now: @now)

    assert_equal %w[job], timeline.kinds
    assert_equal 1, timeline.totals["web"][:count]
    assert_empty timeline.endpoints("web")
  end
end
