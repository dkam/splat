# frozen_string_literal: true

# Path data for the project page's timeline rows (ProjectTimeline). Every strip
# is an SVG with viewBox "0 0 480 h" and preserveAspectRatio="none", stretched
# to its column, so x here is always 0..STRIP whatever the width on screen.
# The views pick the colours; these only say where things go.
module TimelineHelper
  STRIP = 480.0

  def timeline_x(frac) = (frac.to_f.clamp(0.0, 1.0) * STRIP).round(2)

  def timeline_pct(frac) = "#{(frac.to_f.clamp(0.0, 1.0) * 100).round(3)}%"

  # One bar per bucket, scaled to the largest. Returns path data for the bars,
  # the still-filling last bucket (drawn pale), and a hairline for each empty
  # bucket, so "nothing happened" reads differently from "no row".
  def timeline_bars(values, height:, partial: false, max: nil)
    n = values.size
    out = {bars: +"", partial: +"", empty: +""}
    return out if n.zero?

    slot = STRIP / n
    gap = (n > 36) ? 1.0 : 2.0
    width = [slot - gap, 0.5].max.round(2)
    max = (max || values.compact.max).to_f
    values.each_with_index do |v, i|
      x = (i * slot + gap / 2).round(2)
      if v.to_f.positive? && max.positive?
        h = [v.to_f / max * (height - 2), 2].max.round(2)
        path = "M#{x} #{height}h#{width}v#{-h}h#{-width}z"
        (partial && i == n - 1) ? out[:partial] << path : out[:bars] << path
      else
        out[:empty] << "M#{x} #{height - 1}h#{width}v1h#{-width}z"
      end
    end
    out
  end

  # A line through each bucket's centre, scaled to `hi`. A nil value breaks the
  # line rather than dropping it to zero. Returns the line and the area under it.
  def timeline_line(values, height:, hi: nil)
    hi = (hi || values.compact.max.to_f * 1.08).to_f
    out = {line: +"", area: +""}
    return out unless hi.positive?

    n = values.size
    segments = values.each_with_index.chunk_while { |(a, _), (b, _)| !a.nil? && !b.nil? }
    segments.each do |segment|
      points = segment.reject { |v, _| v.nil? }.map do |v, i|
        [((i + 0.5) / n * STRIP).round(1), (height - 1 - v.to_f / hi * (height - 4)).round(1)]
      end
      next if points.empty?

      out[:line] << "M" << points.map { |x, y| "#{x} #{y}" }.join("L")
      out[:area] << "M#{points.first[0]} #{height}L" << points.map { |x, y| "#{x} #{y}" }.join("L") << "L#{points.last[0]} #{height}Z"
    end
    out
  end

  # A dot per bucket that has a value: the sparse form of #timeline_line.
  def timeline_dots(values, height:, hi: nil, radius: 2.4)
    hi = (hi || values.compact.max.to_f * 1.08).to_f
    return "" unless hi.positive?

    n = values.size
    values.each_with_index.filter_map do |v, i|
      next unless v.to_f.positive?
      cx = ((i + 0.5) / n * STRIP).round(1)
      cy = (height - 1 - v.to_f / hi * (height - 4)).round(1)
      "M#{(cx - radius).round(1)} #{cy}a#{radius} #{radius} 0 1 0 #{radius * 2} 0a#{radius} #{radius} 0 1 0 #{-radius * 2} 0"
    end.join
  end

  # A vertical mark at each fraction of the window.
  def timeline_ticks(fracs, top:, bottom:)
    fracs.map { |f| "M#{timeline_x(f)} #{top}V#{bottom}" }.join
  end

  # A bar from each [from, to] fraction pair, at least 1.5 units wide so a
  # one-second run still shows.
  def timeline_spans(spans, top:, bottom:)
    spans.map do |from, to|
      x = timeline_x(from)
      w = [timeline_x(to) - x, 1.5].max.round(2)
      "M#{x} #{top}h#{w}V#{bottom}h#{-w}z"
    end.join
  end

  # Diagonal hatching across a strip, for a monitor that has gone silent.
  def timeline_hatch(height)
    (-height..STRIP.to_i).step(7).map { |x| "M#{x} #{height}L#{x + height} 0" }.join
  end

  # Axis labels: [fraction, UTC label, epoch] at round times for the window.
  def timeline_axis(timeline)
    step = {"1h" => 10.minutes, "6h" => 1.hour, "24h" => 3.hours, "7d" => 1.day, "30d" => 5.days}.fetch(timeline.window.key)
    first = Time.at((timeline.range.begin.to_i / step.to_i + 1) * step.to_i).utc
    format = (step >= 1.day) ? "%a %-d" : "%H:%M"
    format = "%H" if step == 3.hours
    (0..).lazy.map { |i| first + i * step }.take_while { |t| t < timeline.range.end }
      .map { |t| [timeline.frac(t), t.strftime(format), t.to_i] }.to_a
  end

  # A release label is about a third of the strip wide at 953px.
  DEPLOY_LABEL_SPAN = 0.3

  # The deploys that get a label, so that no two labels print over each other;
  # the rest keep their line. A label too near the right edge to fit hangs to
  # the left of its line, so it's the span it covers, not where its line is,
  # that has to clear the last label's.
  def timeline_deploy_labels(timeline)
    clear_from = 0.0
    timeline.deploys.filter_map do |deploy|
      frac = timeline.frac(deploy.at)
      hang_left = frac > 1 - DEPLOY_LABEL_SPAN
      from, to = hang_left ? [frac - DEPLOY_LABEL_SPAN, frac] : [frac, frac + DEPLOY_LABEL_SPAN]
      next if from < clear_from
      clear_from = to
      {deploy: deploy, frac: frac, hang_left: hang_left}
    end
  end

  # "19.12.3+5a6f4862…" → "19.12.3 · 5a6f486"; anything else, shortened.
  def timeline_release(version)
    name, _, build = version.to_s.partition("+")
    return "#{name} · #{build[0, 7]}" if build.match?(/\A\h{7,}\z/)
    format_release(version)
  end

  # "/ hr", "/ 15m", "/ day": what one bucket is.
  def timeline_per_bucket(timeline)
    seconds = timeline.bucket_seconds
    return "/ day" if seconds == 86_400
    return "/ hr" if seconds == 3600
    (seconds >= 3600) ? "/ #{seconds / 3600}h" : "/ #{seconds / 60}m"
  end

  # A window as a heading: "18 Oct 10:00–11:00Z", or "17 Oct 11:00Z – 18 Oct
  # 11:00Z" when it spans days.
  def timeline_window_label(window)
    from = window.begin.utc
    to = window.end.utc
    if to - from <= 1.day && (from.to_date == to.to_date || to == to.beginning_of_day)
      "#{from.strftime("%-d %b %H:%M")}–#{to.strftime("%H:%M")}Z"
    else
      "#{from.strftime("%-d %b %H:%MZ")} – #{to.strftime("%-d %b %H:%MZ")}"
    end
  end

  # "hour", "15-minute bucket", "day": what the cursor reads out at a time.
  def timeline_bucket_noun(timeline)
    seconds = timeline.bucket_seconds
    return "day" if seconds == 86_400
    return "hour" if seconds == 3600
    (seconds >= 3600) ? "#{seconds / 3600}-hour bucket" : "#{seconds / 60}-minute bucket"
  end

  # 24165 → "24.2k", for the peak and low under a row's total.
  def timeline_k(n)
    return "—" if n.nil?
    (n >= 1000) ? "#{(n / 1000.0).round(1)}k" : number_with_delimiter(n.round)
  end

  # A schedule in a few characters: "every 10m", "cron 30 3 * * *".
  def timeline_schedule(monitor)
    case monitor.schedule_type
    when "interval"
      unit = {"minute" => "m", "hour" => "h", "day" => "d", "week" => "w"}.fetch(monitor.schedule_unit.to_s, " #{monitor.schedule_unit}")
      "every #{monitor.schedule_value}#{unit}"
    when "crontab" then "cron #{monitor.schedule_value}"
    else "no schedule"
    end
  end

  # What's wrong with a failing monitor, in the strip it would have drawn in.
  def timeline_monitor_note(monitor)
    case monitor.state
    when "missed"
      since = monitor.last_checkin_at ? "silent since #{monitor.last_checkin_at.utc.strftime("%-d %b %H:%MZ")}" : "never checked in"
      last = monitor.last_duration ? " · its last run took #{format_time_spent(monitor.last_duration * 1000)}" : ""
      since + last
    when "error" then "its last check-in reported an error"
    when "overrun" then "running since #{monitor.in_progress_since&.utc&.strftime("%H:%MZ")}, past its #{monitor.max_runtime}m limit"
    end
  end

  # The runs of a monitor as [from, to, status] fractions; a run still going
  # reaches to now.
  def timeline_runs(timeline, runs)
    runs.map do |run|
      finish = run.finished_at || ((run.status == "in_progress") ? timeline.now : run.started_at)
      [timeline.frac(run.started_at), timeline.frac(finish), run.status]
    end
  end
end
