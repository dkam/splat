# frozen_string_literal: true

require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "sparkline renders one bar per non-zero value" do
    svg = sparkline([1, 0, 3])

    assert_equal 2, svg.scan("<rect").size
  end

  test "sparkline without bar_titles has no hover targets" do
    svg = sparkline([1, 2, 3])

    refute_includes svg, "sparkline-hover"
  end

  test "sparkline with bar_titles adds a full-height hover target per bucket" do
    svg = sparkline([1, 0, 3], height: 64, bar_titles: ["one", "none", "three"])

    assert_equal 3, svg.scan("sparkline-hover").size
    assert_includes svg, "<title>none</title>"
    assert_includes svg, %(height="64")
  end

  test "sparkline escapes bar titles" do
    svg = sparkline([1], bar_titles: ["<script>x</script>"])

    refute_includes svg, "<script>"
    assert_includes svg, "&lt;script&gt;"
  end

  test "sparkline_bucket_titles spaces labels evenly across the range" do
    range = Time.utc(2026, 7, 20)..Time.utc(2026, 7, 27)
    titles = sparkline_bucket_titles([1, 2], range: range) { |v| "p95 #{v}ms" }

    assert_equal ["Mon 20 Jul 00:00 · p95 1ms", "Thu 23 Jul 12:00 · p95 2ms"], titles
  end

  test "sparkline_bucket_titles drops the date inside a day-long window" do
    range = Time.utc(2026, 7, 26, 6)..Time.utc(2026, 7, 27, 6)
    titles = sparkline_bucket_titles([3], range: range) { |v| "#{v} events" }

    assert_equal ["06:00 · 3 events"], titles
  end

  test "sparkline_bucket_titles labels empty buckets instead of skipping them" do
    range = Time.utc(2026, 7, 26)..Time.utc(2026, 7, 27)
    titles = sparkline_bucket_titles([0, 1], range: range, empty: "no events") { |v| "#{v} events" }

    assert_equal "00:00 · no events", titles.first
  end

  test "sparkline_bucket_titles handles empty series and a missing range" do
    assert_empty sparkline_bucket_titles([], range: Time.current..Time.current) { |v| v.to_s }
    assert_empty sparkline_bucket_titles([1, 2], range: nil) { |v| v.to_s }
  end

  test "sparkline skips hover targets for blank titles" do
    svg = sparkline([1, 2], bar_titles: ["one", nil])

    assert_equal 1, svg.scan("sparkline-hover").size
  end

  test "breadcrumbs links every crumb but the current page" do
    html = breadcrumbs(["Issues", "/projects/one/issues"], ["Issue #89", nil])

    assert_includes html, %(<a class="#{ApplicationHelper::BREADCRUMB_LINK}" href="/projects/one/issues">Issues</a>)
    assert_includes html, %(aria-current="page">Issue #89</span>)
    refute_includes html, ">Issue #89</a>"
  end

  test "breadcrumbs puts a separator between crumbs but not before the first" do
    assert_equal 2, breadcrumbs(["A", "/a"], ["B", "/b"], ["C", nil]).scan("aria-hidden").size
    assert_equal 0, breadcrumbs(["A", nil]).scan("aria-hidden").size
  end

  test "breadcrumbs skips nil crumbs and renders nothing when none are left" do
    assert_nil breadcrumbs(nil)
    assert_equal 1, breadcrumbs(["A", "/a"], nil).scan("<li").size
  end
end
