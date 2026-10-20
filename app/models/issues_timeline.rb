# frozen_string_literal: true

# The issues list on the project page's clock (ProjectTimeline keeps it, so the
# two pages' buckets and deploy lines agree): the events of one tab's issues
# and the issues first seen, each drawn per bucket across the window, and a row
# per issue on the page beneath, ticked or barred as the overview's are. It all
# reads live, like the overview's issue rows: resolving one here should show.
#
# The window is one of ProjectTimeline::WINDOWS ending now, or a range a click
# on a bucket opened this page for, cut into the buckets of the nearest window
# at least as long.
class IssuesTimeline
  attr_reader :project, :clock, :status, :environment

  delegate :window, :range, :bucket_seconds, :buckets, :bucket_start, :frac, :now,
    :partial_last_bucket?, :deploys, to: :clock

  def initialize(project, window: nil, range: nil, status: "open", environment: nil, now: Time.current)
    @project = project
    @status = status
    @environment = environment
    @clock = if range
      ProjectTimeline.new(project, ProjectTimeline.window_covering(range.end - range.begin), now: now, range: range)
    else
      ProjectTimeline.new(project, ProjectTimeline::WINDOWS.fetch(window, ProjectTimeline::WINDOWS.fetch(ProjectTimeline::DEFAULT_WINDOW)), now: now)
    end
  end

  # The tab's issues: those in the status, seen in the environment if one is
  # asked for.
  def issues
    scope = project.issues.where(status: status)
    environment ? scope.seen_in_environment(environment, project_id: project.id) : scope
  end

  # Each of the tab's issues with events in the window, and its events per
  # bucket, {issue_id => [n, ...]}: one grouped count, which the Events row, the
  # busiest sort and the rows' bars all add up.
  def bars_by_issue
    @bars_by_issue ||= events_in_window.where(issue_id: issues.select(:id))
      .group(:issue_id, Arel.sql(bucket_sql("timestamp"))).count
      .each_with_object({}) do |((id, bucket), n), bars|
        next unless (index = bucket.to_i).between?(0, buckets - 1)
        (bars[id] ||= Array.new(buckets, 0))[index] += n
      end
  end

  # Events in the window, {issue_id => n}.
  def counts = @counts ||= bars_by_issue.transform_values(&:sum)

  # The issues with events in the window, most first.
  def busiest_ids = counts.sort_by { |id, n| [-n, -id] }.map(&:first)

  def events_per_bucket
    @events_per_bucket ||= Array.new(buckets) { |i| bars_by_issue.each_value.sum { it[i] } }
  end

  # When the tab's issues first appeared, for those that did in the window.
  def first_seen_times
    @first_seen_times ||= issues.where(first_seen: range).order(:first_seen).pluck(:first_seen)
  end

  def first_seen_per_bucket
    @first_seen_per_bucket ||= per_bucket(first_seen_times)
  end

  # A row for each issue on the page, in the page's order: each event marked
  # when there are up to ProjectTimeline::TICK_LIMIT of them in the window, a
  # bar a bucket when there are more, and neither when there are none.
  def rows(page)
    ticked = page.map(&:id).select { (1..ProjectTimeline::TICK_LIMIT).cover?(counts[it].to_i) }
    times = ticked.any? ? events_in_window.where(issue_id: ticked).pluck(:issue_id, :timestamp).group_by(&:first) : {}

    page.map do |issue|
      ticks = times[issue.id]&.map(&:last)&.sort
      ProjectTimeline::IssueRow.new(issue: issue, in_window: counts[issue.id].to_i, times: ticks,
        bars: (bars_by_issue[issue.id] unless ticks), twin_of: nil)
    end
  end

  # The cursor's readout for each bucket (timeline_controller's `facts`): the
  # bucket's events and the issues busiest in it, from the whole tab rather
  # than only the page's rows, and the issues first seen in it.
  def cursor_buckets
    Array.new(buckets) do |i|
      events = events_per_bucket[i]
      busiest = bars_by_issue.filter_map { |id, bars| [id, bars[i]] if bars[i].positive? }
        .max_by(4) { |id, n| [n, -id] }
      facts = [["#{events} #{"event".pluralize(events)}#{": " if busiest.any?}#{busiest.map { |id, n| "##{id} ×#{n}" }.join(" ")}"]]
      if (fresh = first_seen_per_bucket[i]).positive?
        facts << ["#{fresh} new", "text-emerald-700 dark:text-emerald-300"]
      end
      {
        t: bucket_start(i).to_i,
        facts: facts,
        deploys: deploys.select { it.at >= bucket_start(i) && it.at < bucket_start(i) + bucket_seconds }.map(&:version)
      }
    end
  end

  private

  def events_in_window
    scope = Event.where(project_id: project.id, timestamp: range)
    environment ? scope.where(environment: environment) : scope
  end

  def bucket_sql(column) = Analytics::Histogram.time_bucket_sql(origin_epoch: range.begin.to_i, bucket_seconds: bucket_seconds, column: column)

  def per_bucket(times)
    counts = Array.new(buckets, 0)
    times.each do |time|
      index = ((time - range.begin) / bucket_seconds).floor
      counts[index] += 1 if index.between?(0, buckets - 1)
    end
    counts
  end
end
