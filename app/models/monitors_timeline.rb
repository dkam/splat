# frozen_string_literal: true

# The monitors page on the project page's clock (ProjectTimeline keeps it, so
# its buckets and deploy lines agree with the overview's): a row per monitor,
# grouped by how often it runs and drawn as the overview's monitor rows are,
# with the check-ins its schedule said were due, so that a miss shows as the
# place a run should have been, not only as a state.
#
# What was due depends on the schedule. A crontab names times, each kept by a
# run starting within the monitor's margin of it (or EARLY before). An
# interval names only a spacing, so what it can miss is a gap: longer than the
# interval and its margin with no check-in, each interval of it past the
# margin one check-in missed. Nothing before the project's first kept
# check-in counts either way (retention, or check-ins only began to be kept
# then): nothing is known about it.
class MonitorsTimeline
  # kept: true or false; nil for one not yet due, or due before what's known.
  Slot = Data.define(:at, :kept)
  # A stretch an interval monitor was silent for, from when it was due.
  Gap = Data.define(:from, :to)

  # due and kept: the check-ins due in the window that can be judged, and
  # those that came; nil for a monitor with no schedule to judge it by.
  # runs, errors and lost count its check-ins in the window; avg and max are
  # their durations in seconds.
  Row = Data.define(:base, :period, :slots, :gaps, :due, :kept, :runs_in_window, :errors, :lost, :avg, :max) do
    delegate :monitor, :runs, :coverage, :run_count, :failing?, to: :base
  end

  Group = Data.define(:key, :title, :rows)

  # [key, title, the longest period it takes].
  CADENCES = [
    ["minutes", "Every few minutes", 15.minutes],
    ["hours", "Hourly", 12.hours],
    ["days", "Daily", 1.day],
    ["weeks", "Weekly and less often", nil]
  ].freeze

  # A run starting this much before its crontab's time still keeps it.
  EARLY = 1.minute
  # A missed monitor silent for longer than this, or three of its periods if
  # that's longer, has most likely been retired rather than broken, so it's
  # folded away at the foot rather than listed first as failing.
  QUIET_AFTER = 7.days

  RED = "text-red-700 dark:text-red-300"
  GREEN = "text-emerald-700 dark:text-emerald-300"
  FACTS = 6

  attr_reader :project, :clock

  delegate :window, :range, :bucket_seconds, :buckets, :bucket_start, :frac, :now,
    :partial_last_bucket?, :deploys, to: :clock

  def initialize(project, window: nil, range: nil, now: Time.current)
    @project = project
    @clock = if range
      ProjectTimeline.new(project, ProjectTimeline.window_covering(range.end - range.begin), now: now, range: range)
    else
      ProjectTimeline.new(project, ProjectTimeline::WINDOWS.fetch(window, ProjectTimeline::WINDOWS.fetch(ProjectTimeline::DEFAULT_WINDOW)), now: now)
    end
  end

  # Where what's known of the project's check-ins begins: its earliest kept.
  def known_from
    @known_from ||= CronCheckIn.where(project_id: project.id).minimum(:started_at) || now
  end

  def rows
    @rows ||= clock.monitor_rows.map { build_row(it) }
  end

  # Failing first, then by cadence, then those gone quiet; empty ones left out.
  def groups
    @groups ||= begin
      quiet, live = rows.partition { quiet?(it) }
      failing, ok = live.partition(&:failing?)
      unscheduled, scheduled = ok.partition { it.period.nil? }
      by_cadence = scheduled.group_by { |row| CADENCES.find { |_, _, upto| upto.nil? || row.period <= upto }.first }

      [Group.new("failing", "Failing", failing),
        *CADENCES.map { |key, title, _| Group.new(key, title, by_cadence.fetch(key, [])) },
        Group.new("unscheduled", "No schedule", unscheduled),
        Group.new("quiet", "Gone quiet", quiet)].reject { it.rows.empty? }
    end
  end

  def quiet?(row)
    last = row.monitor.last_checkin_at || row.monitor.created_at
    row.monitor.state == "missed" && last < now - [QUIET_AFTER, 3 * row.period.to_i].max
  end

  # The cursor's readout for each bucket (timeline_controller's `facts`): what
  # was missed in it, what failed, and the runs long enough to name. Those
  # gone quiet would be missing in every bucket, so they're left out.
  def cursor_buckets
    live = rows.reject { quiet?(it) }
    Array.new(buckets) do |i|
      from = bucket_start(i)
      to = from + bucket_seconds
      facts = live.flat_map { facts_in(it, from, to) }.uniq
      facts = [["nothing missed", GREEN]] if facts.empty?
      facts = facts.first(FACTS) + [["+#{facts.size - FACTS} more"]] if facts.size > FACTS + 1
      {
        t: from.to_i,
        facts: facts,
        deploys: deploys.select { it.at >= from && it.at < to }.map(&:version)
      }
    end
  end

  private

  def build_row(base)
    monitor = base.monitor
    stat = stats.fetch(monitor.id, {})
    slots = crontab_slots(base) if monitor.schedule_type == "crontab"
    gaps, due, kept = if slots
      judged = slots.reject { it.kept.nil? }
      [nil, judged.size, judged.count(&:kept)]
    elsif monitor.interval_seconds
      interval_gaps(monitor)
    end
    going_now = (monitor.in_progress_since && range.cover?(monitor.in_progress_since)) ? 1 : 0

    Row.new(base: base, period: period_of(monitor), slots: slots, gaps: gaps, due: due, kept: kept,
      runs_in_window: stat[:runs].to_i, errors: stat[:errors].to_i, lost: [stat[:going].to_i - going_now, 0].max,
      avg: stat[:avg], max: stat[:max])
  end

  # Each monitor's check-ins in the window, but for the misses the evaluator
  # marked: one grouped pass.
  def stats
    @stats ||= CronCheckIn.where(project_id: project.id, started_at: range).where.not(status: "missed")
      .group(:cron_monitor_id)
      .pluck(:cron_monitor_id, Arel.sql("COUNT(*)"), Arel.sql("SUM(status = 'error')"),
        Arel.sql("SUM(status = 'in_progress')"), Arel.sql("AVG(duration)"), Arel.sql("MAX(duration)"))
      .to_h { |id, runs, errors, going, avg, max| [id, {runs: runs, errors: errors, going: going, avg: avg, max: max}] }
  end

  # What's known of a monitor in the window starts with the window, the
  # project's first kept check-in, or the monitor itself, whichever is last.
  def observed_from(monitor) = [range.begin, known_from, monitor.created_at].max

  def observed_to = [range.end, now].min

  def cron_for(monitor)
    (@crons ||= {}).fetch(monitor.id) do
      @crons[monitor.id] = (Fugit.parse_cron(monitor.crontab_expression) if monitor.schedule_type == "crontab")
    rescue ArgumentError
      @crons[monitor.id] = nil
    end
  end

  def period_of(monitor) = monitor.interval_seconds || cron_for(monitor)&.rough_frequency

  # The crontab's times in the window, each judged by the runs drawn: kept by
  # a run within its margin; otherwise missed, unless its margin ran out before
  # anything was known, or hasn't run out yet. nil when it names more than
  # ProjectTimeline::TICK_LIMIT, or its runs are too many to draw one by one.
  def crontab_slots(base)
    monitor = base.monitor
    cron = cron_for(monitor)
    return nil if cron.nil? || (base.runs.nil? && base.run_count.positive?)

    times = []
    at = range.begin - 1
    while (at = cron.next_time(at).to_t.utc) < range.end
      return nil if times.size >= ProjectTimeline::TICK_LIMIT
      times << at
    end

    starts = Array(base.runs).reject { it.status == "missed" }.map(&:started_at)
    from = observed_from(monitor)
    margin = monitor.margin_seconds
    times.map do |due|
      deadline = due + margin
      kept = if starts.any? { it.between?(due - EARLY, deadline) } then true
      elsif deadline < from || deadline > now then nil
      else false
      end
      Slot.new(at: due, kept: kept)
    end
  end

  # An interval monitor's silences in the window, and the check-ins due and
  # kept: [gaps, due, kept]. A silence a run began was due an interval after
  # it; one the window opens in, from the start.
  def interval_gaps(monitor)
    interval = monitor.interval_seconds
    margin = monitor.margin_seconds
    from = observed_from(monitor)
    to = observed_to
    return [[], 0, 0] if to - from < interval

    due = ((to - from) / interval).floor
    first, last, pairs = silences.fetch(monitor.id, [nil, nil, []])
    return [[Gap.new(from: from, to: to)], due, 0] if first.nil?

    # [from, to, whether a run began it]
    stretches = [[from, first, false]]
    pairs.each { |prev, at| stretches << ((prev < from) ? [from, at, false] : [prev, at, true]) if at > from }
    stretches << [last, to, true]
    stretches.select! { |a, b, _| b - a > interval + margin }

    missed = stretches.sum { |a, b, _| ((b - a - margin) / interval).floor }
    gaps = stretches.map { |a, b, ran| Gap.new(from: ran ? a + interval : a, to: b) }
    [gaps, due, [due - missed, 0].max]
  end

  # For every interval monitor at once, in one pass with a window function:
  # {id => [first start, last start, [[start, next start], ...]]}, the pairs
  # being those further apart than its interval and margin. It reaches back by
  # the longest of those before the window, to find the run before a silence
  # the window opens in.
  def silences
    @silences ||= begin
      thresholds = project.cron_monitors.filter_map { [it.id, it.interval_seconds + it.margin_seconds] if it.interval_seconds }.to_h
      if thresholds.empty?
        {}
      else
        threshold = "CASE cron_monitor_id #{thresholds.map { |id, s| "WHEN #{id.to_i} THEN #{s.to_i}" }.join(" ")} END"
        seconds = ->(column) { "CAST(strftime('%s', #{column}) AS INTEGER)" }
        sql = CronCheckIn.sanitize_sql_array([<<~SQL, project.id, thresholds.keys, [range.begin, known_from].max - thresholds.values.max, observed_to])
          SELECT cron_monitor_id, prev, started_at, nxt FROM (
            SELECT cron_monitor_id, started_at,
              LAG(started_at) OVER (PARTITION BY cron_monitor_id ORDER BY started_at) AS prev,
              LEAD(started_at) OVER (PARTITION BY cron_monitor_id ORDER BY started_at) AS nxt
            FROM cron_check_ins
            WHERE project_id = ? AND cron_monitor_id IN (?) AND status <> 'missed' AND started_at >= ? AND started_at < ?
          ) WHERE prev IS NULL OR nxt IS NULL OR #{seconds.call("started_at")} - #{seconds.call("prev")} > #{threshold}
        SQL
        utc = ActiveSupport::TimeZone["UTC"]
        CronCheckIn.connection.select_rows(sql).each_with_object({}) do |(id, prev, at, nxt), out|
          entry = out[id] ||= [nil, nil, []]
          at = utc.parse(at)
          entry[0] = at if prev.nil?
          entry[1] = at if nxt.nil?
          entry[2] << [utc.parse(prev), at] if prev
        end
      end
    end
  end

  def facts_in(row, from, to)
    slug = row.monitor.slug
    facts = []
    facts += Array(row.slots).select { it.kept == false && it.at >= from && it.at < to }.map { ["#{slug} missed", RED] }
    facts += Array(row.gaps).select { it.from < to && it.to > from }.map { ["#{slug} silent", RED] }
    Array(row.runs).each do |run|
      next if run.started_at >= to || (run.finished_at || run.started_at) < from
      if run.status == "error"
        facts << ["#{slug} error", RED]
      elsif run.status == "ok" && run.duration.to_f >= 60
        facts << ["#{slug} #{span(run.duration)}"]
      end
    end
    facts
  end

  # As ApplicationHelper#format_time_spent puts it: "4m 9s", "1h 23m".
  def span(seconds)
    seconds = seconds.round
    return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600
    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end
end
