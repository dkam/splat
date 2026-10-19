# frozen_string_literal: true

# The performance page's one clock: the project page's axis (ProjectTimeline
# keeps the clock, so the two pages' buckets and deploy lines agree), with
# throughput and p95 drawn for each TransactionKind apart, and each kind's
# endpoints beneath. A slow hour of jobs and a slow hour of requests then read
# as two things, where one Latency row averaged them into neither.
#
# The window is one of ProjectTimeline::WINDOWS ending now, or a range another
# page opened this one for (a bucket clicked on a timeline), cut into the
# buckets of the nearest window at least as long.
class PerformanceTimeline
  # Endpoints drawn per kind: fewer each when every kind is on the page.
  ROWS_PER_KIND = 10
  ROWS_ONE_KIND = 25

  # Aggregate reads over hours of data, like the project page's; the feed
  # beneath stays live.
  PERF_TTL = 1.minute

  Signal = Data.define(:kind, :throughput, :p95s, :percentiles)

  attr_reader :project, :clock, :kind, :environment, :name_query

  delegate :window, :range, :bucket_seconds, :buckets, :bucket_start, :frac, :now,
    :partial_last_bucket?, :deploys, to: :clock

  def initialize(project, window: nil, range: nil, kind: nil, environment: nil, name_query: nil, now: Time.current)
    @project = project
    @kind = kind
    @environment = environment
    @name_query = name_query
    @clock = if range
      span = range.end - range.begin
      fit = ProjectTimeline::WINDOWS.values.find { it.span >= span } || ProjectTimeline::WINDOWS.values.last
      ProjectTimeline.new(project, fit, now: now, range: whole_hour_buckets(range, fit.buckets))
    else
      ProjectTimeline.new(project, ProjectTimeline::WINDOWS.fetch(window, ProjectTimeline::WINDOWS.fetch("24h")), now: now)
    end
  end

  # Under an hour a bucket, the hourly rollups can't answer: read the raw rows,
  # which a window that short keeps to a few hours' worth.
  def raw? = bucket_seconds < 3600

  # The kinds drawn: the one asked for, or each with traffic, web first.
  def kinds = kind ? [kind] : TransactionKind::KINDS.select { totals.key?(it) }

  def totals = perf[:totals]

  # Built from the cached hashes on the way out, so the cache holds no class
  # of this file's.
  def signal(kind)
    (@signals ||= {})[kind] ||= (s = perf[:signals][kind]) && Signal.new(kind: kind, **s)
  end

  # A kind's endpoints, as ProjectTimeline::Endpoint rows: a p95 line when
  # there are enough requests a bucket for one, dots when there aren't.
  def endpoints(kind)
    (@endpoints ||= {})[kind] ||= perf[:endpoints].fetch(kind, []).map do |stats|
      mode = (stats["count"].to_f / buckets >= ProjectTimeline::DENSE_PER_BUCKET) ? :line : :marks
      ProjectTimeline::Endpoint.new(stats: stats, p95s: stats["p95_series"], mode: mode)
    end
  end

  # Whether any row's time is scaled by a sample rate, so the heading can say.
  def scaled? = kinds.any? { |k| endpoints(k).any? { it.stats["rated_count"].to_i.positive? } }

  # Each kind's share of the time spent, sample rates applied: Booko samples
  # requests at 1% and jobs at 10%, so the recorded times alone would make the
  # jobs look ten times bigger beside the requests than they are.
  def share(kind)
    whole = totals.values.sum { it[:est_time_spent] }
    whole.positive? ? totals.dig(kind, :est_time_spent).to_f / whole : 0.0
  end

  # The cursor's readout for each bucket (timeline_controller's `facts`): each
  # kind's count and p95, then the busiest endpoints' p95.
  def cursor_buckets
    lines = kinds.flat_map { |k| endpoints(k).select(&:line?).first(2) }
    Array.new(buckets) do |i|
      facts = kinds.map do |k|
        s = signal(k)
        p95 = s.p95s[i]
        ["#{TransactionKind::NOUNS[k]} #{s.throughput[i].to_i}#{" · p95 #{format_ms(p95)}" if p95}"]
      end
      lines.each { |e| facts << ["#{e.name} p95 #{format_ms(e.p95s[i])}"] if e.p95s[i].to_i.positive? }
      {
        t: bucket_start(i).to_i,
        facts: facts,
        deploys: deploys.select { it.at >= bucket_start(i) && it.at < bucket_start(i) + bucket_seconds }.map(&:version)
      }
    end
  end

  private

  # A bucket of an hour or more has to be whole hours, or the rollups can't
  # tile it and the series come back with a different number of buckets. A
  # timeline's own buckets always are; a window typed by hand (two days, say)
  # is widened back to the whole hours that make it up.
  def whole_hour_buckets(range, buckets)
    seconds = (range.end - range.begin) / buckets
    return range if seconds < 3600 || (seconds % 3600).zero?

    (range.end - (seconds / 3600.0).ceil.hours * buckets)...range.end
  end

  def format_ms(ms) = (ms >= 1000) ? "#{(ms / 1000.0).round(1)}s" : "#{ms.round}ms"

  def perf
    @perf ||= Rails.cache.fetch(
      ["performance_timeline/v1", project.id, range.begin.to_i, range.end.to_i, buckets, kind, environment, name_query],
      expires_in: PERF_TTL, race_condition_ttl: 10.seconds
    ) do
      filters = {project_id: project.id, environment: environment}
      rows, totals = Transaction.stats_by_endpoint_by_kind(range, **filters, name_query: name_query,
        limit: kind ? ROWS_ONE_KIND : ROWS_PER_KIND, only: kind, raw: raw?)
      shown = kind ? [kind] : TransactionKind::KINDS.select { totals.key?(it) }

      names = rows.values.flatten.map { it["transaction_name"] }.uniq
      p95s = Transaction.p95_by_bucket(transaction_names: names, time_range: range, buckets: buckets, **filters)

      signals = shown.to_h do |k|
        series = {time_range: range, buckets: buckets, name_query: name_query, kind: k, **filters}
        percentiles = if raw?
          Transaction.percentiles_raw(range, **filters, name_query: name_query, kind: k)
        else
          Transaction.percentiles(range, **filters, name_query: name_query, kind: k)
        end
        [k, {throughput: Transaction.volume_by_bucket(**series), p95s: Transaction.p95_series(**series),
             percentiles: percentiles}]
      end

      {
        totals: totals,
        signals: signals,
        endpoints: rows.transform_values { |list| list.map { it.merge("p95_series" => p95s[it["transaction_name"]]) } }
      }
    end
  end
end
