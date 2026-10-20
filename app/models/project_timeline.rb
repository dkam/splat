# frozen_string_literal: true

# The project page's one clock: throughput, latency, events, issues, endpoints
# and monitors as rows on one time axis, so a deploy, a burst of errors and a
# latency jump that happened together line up down the page.
#
# Each row picks how to draw itself from how much it has. An endpoint with
# DENSE_PER_BUCKET requests a bucket gets a p95 line; with fewer, a bucket's
# p95 is just its slowest request, so it gets a mark per bucket instead. An
# issue or a monitor with up to TICK_LIMIT events or runs in the window gets
# one mark for each; with more, a bar per bucket. A row with nothing in the
# window isn't drawn, but is counted in a folded line that says so. A project
# with too little to draw at 24h opens at 7d (see .for).
class ProjectTimeline
  Window = Data.define(:key, :span, :buckets)

  WINDOWS = [
    Window.new("1h", 1.hour, 12),
    Window.new("6h", 6.hours, 24),
    Window.new("24h", 24.hours, 24),
    Window.new("7d", 7.days, 42),
    Window.new("30d", 30.days, 30)
  ].index_by(&:key).freeze
  DEFAULT_WINDOW = "24h"
  WIDER_WINDOW = "7d"

  DENSE_PER_BUCKET = 20
  # Fewer issue, endpoint and monitor rows than this at 24h, and the default
  # view widens to 7d.
  MIN_ACTIVE_ROWS = 3
  TICK_LIMIT = 300
  ENDPOINT_ROWS = 8
  ISSUE_ROWS = 12
  TWIN_TITLE_PREFIX = 20
  # Two reports of one request can land either side of a second boundary.
  TWIN_SECONDS = 2

  # The transaction half is aggregate reads over hours of data; issues and
  # monitors stay live, since resolving an issue on this page should show.
  PERF_TTL = 2.minutes

  FAILING_STATES = %w[missed error overrun].freeze

  Endpoint = Data.define(:stats, :p95s, :mode) do
    def name = stats["transaction_name"]
    def line? = mode == :line
  end

  # times: each event's timestamp, when there are few enough to mark one by
  # one; bars: events per bucket, when there aren't.
  IssueRow = Data.define(:issue, :in_window, :times, :bars, :twin_of)

  # runs: CronCheckIns, when there are few enough to draw one by one;
  # coverage: {bucket => {status => count}}, when there aren't.
  MonitorRow = Data.define(:monitor, :runs, :coverage, :run_count) do
    def failing? = FAILING_STATES.include?(monitor.state)
  end

  Deploy = Data.define(:at, :version)

  attr_reader :project, :window, :range, :bucket_seconds, :now, :widened_from

  # The window asked for, or 24h — widened to 7d when 24h has too little to
  # show. widened_from says so, for the page to explain.
  def self.for(project, window: nil, now: Time.current)
    return new(project, WINDOWS.fetch(window), now: now) if WINDOWS.key?(window)

    timeline = new(project, WINDOWS.fetch(DEFAULT_WINDOW), now: now)
    return timeline unless timeline.quiet?

    new(project, WINDOWS.fetch(WIDER_WINDOW), now: now, widened_from: DEFAULT_WINDOW)
  end

  # The window whose buckets cut a range another page was opened for (a bucket
  # clicked on a timeline): the shortest at least as long, or else the longest.
  def self.window_covering(span)
    WINDOWS.values.find { it.span >= span } || WINDOWS.values.last
  end

  # range: a window other than the one ending now, such as a bucket another
  # page was opened for, cut into window.buckets. The performance page's clock
  # (PerformanceTimeline) is one of these.
  def initialize(project, window, now: Time.current, widened_from: nil, range: nil)
    @project = project
    @window = window
    @now = now
    @widened_from = widened_from
    @bucket_seconds = ((range ? range.end - range.begin : window.span) / window.buckets).to_i
    @range = range || begin
      finish = window_end
      (finish - window.span)..finish
    end
  end

  def buckets = window.buckets

  def bucket_start(index) = range.begin + index * bucket_seconds

  # Where a time falls across the window, 0 to 1.
  def frac(time) = ((time - range.begin) / (range.end - range.begin)).clamp(0.0, 1.0)

  # The last bucket is still filling, so its count isn't comparable yet.
  def partial_last_bucket? = now < range.end

  def quiet? = active_rows < MIN_ACTIVE_ROWS

  def active_rows
    issue_rows.size + endpoints.count(&:line?) + monitor_rows.count { it.run_count.positive? }
  end

  # ---- Transactions and logs (cached together; see PERF_TTL). ----

  def throughput = perf[:throughput]
  def latency = perf[:p95]
  def percentiles = perf[:percentiles]
  def logs_per_bucket = perf[:logs]

  def endpoints
    @endpoints ||= perf[:endpoints].map do |stats|
      mode = (stats["count"].to_f / buckets >= DENSE_PER_BUCKET) ? :line : :marks
      Endpoint.new(stats: stats, p95s: stats["p95_series"], mode: mode)
    end
  end

  # ---- Events and issues. ----

  def events_per_bucket
    @events_per_bucket ||= begin
      counts = events_in_window.group(Arel.sql(bucket_sql("timestamp"))).count
      Array.new(buckets) { |i| counts[i].to_i }
    end
  end

  # The open issues with events in the window, busiest first (then busiest
  # overall), each followed by its twin if it has one.
  def issue_rows
    @issue_rows ||= begin
      open = issues_with_events.values.select(&:open?)
        .sort_by { |issue| [-issue_counts[issue.id], -issue.count.to_i, -issue.id] }
        .first(ISSUE_ROWS)
      pair_twins(build_issue_rows(open))
    end
  end

  def open_issues_with_events = issues_with_events.values.count(&:open?)

  def open_issue_count
    @open_issue_count ||= project.issues.open.count
  end

  def quiet_open_issue_count = open_issue_count - open_issues_with_events

  # How many users each drawn issue has reached, {issue_id => count}, in one
  # query for every row; absent where no event said who its user was.
  def issue_users
    @issue_users ||= IssueFacet.counts_by_issue(issue_rows.map { it.issue.id }, :user)
  end

  # Ignored issues still firing, folded into one row: [issues, event count, row].
  def ignored_fold = @ignored_fold ||= fold(:ignored?)

  # Resolved issues with events in the window (fixed since, or resolved in a
  # release these events predate), folded the same way, so that every event in
  # the Events row is in some row below it.
  def resolved_fold = @resolved_fold ||= fold(:resolved?)

  # ---- Monitors. ----

  # Failing monitors first, then by slug.
  def monitor_rows
    @monitor_rows ||= begin
      scope = CronCheckIn.where(project_id: project.id).overlapping(range)
      counts = scope.group(:cron_monitor_id).count
      few, many = counts.keys.partition { |id| counts[id] <= TICK_LIMIT }
      runs = few.any? ? scope.where(cron_monitor_id: few).order(:started_at).to_a.group_by(&:cron_monitor_id) : {}
      coverage = Hash.new { |h, k| h[k] = Hash.new { |b, i| b[i] = Hash.new(0) } }
      if many.any?
        scope.where(cron_monitor_id: many).group(:cron_monitor_id, Arel.sql(bucket_sql("started_at")), :status).count
          .each { |(id, bucket, status), n| coverage[id][bucket.to_i][status] += n }
      end

      project.cron_monitors.by_slug.map do |monitor|
        MonitorRow.new(monitor: monitor, runs: runs[monitor.id], coverage: (coverage[monitor.id] if many.include?(monitor.id)),
          run_count: counts[monitor.id].to_i)
      end.sort_by { |row| [row.failing? ? 0 : 1, row.monitor.slug] }
    end
  end

  # ---- Deploys. ----

  def deploys
    @deploys ||= project.releases.where(first_seen_at: range).order(:first_seen_at)
      .pluck(:first_seen_at, :version).map { |at, version| Deploy.new(at: at, version: version) }
  end

  # What the cursor reads out for each bucket: the page draws it, the
  # timeline controller shows the bucket under the pointer.
  def cursor_buckets
    lines = endpoints.select(&:line?).first(3)
    Array.new(buckets) do |i|
      {
        t: bucket_start(i).to_i,
        txn: throughput[i],
        p95: latency[i],
        events: events_per_bucket[i],
        issues: issue_rows.filter_map { |row| (n = events_in_bucket(row, i)).positive? ? ["##{row.issue.id}", n] : nil }.first(4),
        endpoints: lines.filter_map { |e| [e.name, e.p95s[i]] if e.p95s[i].to_i.positive? },
        monitors: monitors_in_bucket(i),
        # Named here because a crowded window drops some deploys' labels.
        deploys: deploys.select { it.at >= bucket_start(i) && it.at < bucket_start(i) + bucket_seconds }.map(&:version)
      }
    end
  end

  # The monitors worth naming in a bucket: a run that took a minute or more,
  # or one that didn't go well. A heartbeat's routine run every bucket isn't.
  def monitors_in_bucket(index)
    from = bucket_start(index)
    to = from + bucket_seconds
    monitor_rows.filter_map do |row|
      runs = Array(row.runs).select do |run|
        finish = run.finished_at || run.started_at
        run.started_at < to && finish >= from && (run.status != "ok" || run.duration.to_f >= 60)
      end
      next if runs.empty?
      bad = runs.map(&:status).find { it != "ok" }
      [row.monitor.slug, bad]
    end.first(4)
  end

  def events_in_bucket(row, index)
    return row.bars[index].to_i if row.bars
    from = bucket_start(index)
    row.times.count { |t| t >= from && t < from + bucket_seconds }
  end

  private

  # Hour-aligned for the hourly rollups (the current hour is the last bucket);
  # finer windows end at the next bucket boundary instead.
  def window_end
    if bucket_seconds >= 3600
      Analytics::Histogram.hour_bucket(now) + 1.hour
    else
      Time.at((now.to_i / bucket_seconds + 1) * bucket_seconds).utc
    end
  end

  def bucket_sql(column) = Analytics::Histogram.time_bucket_sql(origin_epoch: range.begin.to_i, bucket_seconds: bucket_seconds, column: column)

  def perf
    @perf ||= Rails.cache.fetch(["project_timeline/v1", project.id, window.key, range.end.to_i],
      expires_in: PERF_TTL, race_condition_ttl: 10.seconds) do
      # The hourly rollups count whole hours, so a 1h window read from them
      # would take in two. Finer windows read the raw rows, a few hours' worth.
      stats = if bucket_seconds < 3600
        Transaction.stats_by_endpoint_raw(range, project_id: project.id, limit: ENDPOINT_ROWS)
      else
        Transaction.stats_by_endpoint_with_impact(range, project_id: project.id, limit: ENDPOINT_ROWS)
      end
      p95s = Transaction.p95_by_bucket(transaction_names: stats.map { it["transaction_name"] }.uniq,
        time_range: range, buckets: buckets, project_id: project.id)
      {
        throughput: Transaction.volume_by_bucket(project_id: project.id, time_range: range, buckets: buckets),
        p95: Transaction.p95_series(project_id: project.id, time_range: range, buckets: buckets),
        percentiles: Transaction.percentiles(range, project_id: project.id),
        endpoints: stats.map { it.merge("p95_series" => p95s[it["transaction_name"]]) },
        # A grouped count down the (project_id, timestamp) index: Booko's day is
        # ~125k rows. Cached with the rest because a 7d window is ten times that.
        logs: begin
          counts = Log.where(project_id: project.id, timestamp: range).group(Arel.sql(bucket_sql("timestamp"))).count
          Array.new(buckets) { |i| counts[i].to_i }
        end
      }
    end
  end

  def events_in_window = Event.where(project_id: project.id, timestamp: range)

  def fold(status)
    issues = issues_with_events.values.select(&status)
    [issues, issues.sum { issue_counts[it.id] }, merge_rows(build_issue_rows(issues))]
  end

  def issue_counts
    @issue_counts ||= events_in_window.where.not(issue_id: nil).group(:issue_id).count
  end

  def issues_with_events
    @issues_with_events ||= Issue.where(id: issue_counts.keys).index_by(&:id)
  end

  def build_issue_rows(issues)
    ticked, barred = issues.map(&:id).partition { |id| issue_counts[id] <= TICK_LIMIT }
    times = ticked.any? ? events_in_window.where(issue_id: ticked).pluck(:issue_id, :timestamp).group_by(&:first) : {}
    bars = barred.any? ? Event.event_counts_by_bucket(issue_ids: barred, time_range: range, buckets: buckets, project_id: project.id) : {}

    issues.map do |issue|
      IssueRow.new(issue: issue, in_window: issue_counts[issue.id], times: times[issue.id]&.map(&:last)&.sort,
        bars: bars[issue.id], twin_of: nil)
    end
  end

  # One row standing for several issues, for a folded line.
  def merge_rows(rows)
    return nil if rows.empty?
    if rows.all?(&:times)
      IssueRow.new(issue: nil, in_window: rows.sum(&:in_window), times: rows.flat_map(&:times).sort, bars: nil, twin_of: nil)
    else
      bars = Array.new(buckets) { |i| rows.sum { events_in_bucket(it, i) } }
      IssueRow.new(issue: nil, in_window: rows.sum(&:in_window), times: nil, bars: bars, twin_of: nil)
    end
  end

  # Two open issues whose events landed together, each within TWIN_SECONDS of
  # its counterpart, under titles that start the same way (TWIN_TITLE_PREFIX
  # characters), are one failure reported twice: an exception and the error
  # that wrapped it, say. The twin is drawn under the issue with more events
  # overall, and says whose twin it is.
  def pair_twins(rows)
    twin_of = {}
    candidates = rows.select(&:times).sort_by { |row| [-row.issue.count.to_i, row.issue.id] }
    candidates.each_with_index do |primary, i|
      next if twin_of.key?(primary.issue.id)
      candidates.drop(i + 1).each do |row|
        next if twin_of.key?(row.issue.id) || !twins?(primary, row)
        twin_of[row.issue.id] = primary.issue.id
      end
    end

    rows.reject { twin_of.key?(it.issue.id) }.flat_map do |row|
      [row] + rows.select { twin_of[it.issue.id] == row.issue.id }.map { it.with(twin_of: row.issue.id) }
    end
  end

  def twins?(a, b)
    a.times.size == b.times.size &&
      a.times.zip(b.times).all? { |x, y| (x - y).abs <= TWIN_SECONDS } &&
      common_prefix(a.issue.title, b.issue.title) >= TWIN_TITLE_PREFIX
  end

  def common_prefix(a, b)
    a.to_s.each_char.zip(b.to_s.each_char).take_while { |x, y| x == y }.size
  end
end
