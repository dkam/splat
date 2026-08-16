# frozen_string_literal: true

# Every MCP tool Splat exposes, and the formatting that turns query results into
# the markdown an agent reads. Extracted from Mcp::McpController when the
# hand-rolled JSON-RPC layer was replaced by the official `mcp` gem (v1.15.0):
# the protocol is the gem's problem now, and this is everything that was never
# about the protocol.
#
# A plain object, instantiated once per request by SplatMcpServer.build. Nothing
# here touches the request, the session, or the controller — a tool method takes
# a string-keyed argument hash and returns an MCP::Tool::Response.
#
# Methods are public because the tool wrappers in SplatMcpServer dispatch to them
# by name; only the names registered there are reachable from outside.
class SplatMcpTools
  # For time_ago_in_words, which list_monitors uses. Came free from the
  # controller's `helpers`; a plain object has to ask for it.
  include ActionView::Helpers::DateHelper

  class << self
    # Both are needed while *building* the tool schemas, before any instance
    # exists — tools/list advertises the live retention ceiling.
    def max_hours(source) = new.max_hours(source)

    def hours_description(source, label = "Number of hours to look back")
      new.hours_description(source, label)
    end
  end

  # Raised when the caller names a project that doesn't exist, or names one
  # ambiguously. Surfaced to the agent as a tool error (isError: true) rather
  # than a JSON-RPC error, so it can read the message and correct the argument
  # itself. The message is composed at the raise site, since the two cases call
  # for different advice.
  class ProjectResolutionError < StandardError; end

  # Raised for an unusable time window — bad ISO 8601, inverted bounds, or a
  # window that predates retention entirely. Same tool-error treatment.
  class WindowError < StandardError; end

  # Returns nil only when the caller omitted `project` entirely (meaning:
  # don't filter), otherwise the id. A present-but-blank value is an error,
  # not "every project" — an agent that built the argument from a lookup that
  # came back empty should be told so, not handed the whole instance.
  #
  # Both slug and name match case-insensitively: an agent passing a
  # title-cased slug is naming a project that plainly exists, so a BINARY
  # compare rejecting it is just a spurious failure. Slug wins over name (it's
  # the stable identifier in the DSN) and both win over id, so a numeric-looking
  # slug still beats a coincidental id.
  #
  # One lookup per tier, tried in priority order and only until one hits. Only
  # the slug and id tiers are indexed (LOWER(slug) can't use index_projects_on_slug,
  # and `name` has no index at all), but a single-tenant instance has a handful
  # of projects and this runs at most once per tool call.
  #
  # LOWER() rather than a plain compare because generate_slug only fires when
  # slug is blank — an explicitly-supplied slug is stored verbatim, so a
  # mixed-case one is possible and shouldn't be unfindable.
  def resolve_project_id(args)
    return nil unless args.key?("project")

    raw = args["project"].to_s.strip
    raise_unknown_project(args["project"].inspect) if raw.blank?

    folded = raw.downcase
    project = Project.find_by("LOWER(slug) = ?", folded)
    project ||= disambiguate(Project.where("LOWER(name) = ?", folded).to_a, raw)
    project ||= Project.find_by(id: raw) if raw.match?(/\A\d+\z/)
    raise_unknown_project(raw) unless project
    project.id
  end

  def raise_unknown_project(raw)
    raise ProjectResolutionError,
      "Unknown project: #{raw}. Available projects: #{Project.order(:name).pluck(:slug).join(", ")}"
  end

  # ---- Window ceilings. ----
  #
  # A tool's maximum window is whatever its backing table still holds, read off
  # Setting rather than a blanket constant. The windowed readers in
  # TransactionAnalytics serve stats/percentiles/series from
  # transaction_hourly_stats + transaction_histograms, which retention keeps on
  # the long histograms clock (:rollup); tools that list or rank individual
  # rows scan raw transactions (:transactions), and logs have their own shorter
  # clock (:logs). A `release` filter forces the raw fallback — release isn't
  # carried on either aggregate — so those callers pass :transactions instead.
  RETENTION_SOURCE = {
    rollup: :histograms_retention_days,
    transactions: :transactions_data_retention_days,
    logs: :logs_data_retention_days
  }.freeze

  def max_hours(source)
    Setting.instance.public_send(RETENTION_SOURCE.fetch(source)) * 24
  end

  # Resolve a tool's time window, and clamp it to what retention still holds.
  #
  # Every window used to be "N hours back from now", which makes a past moment
  # unreachable: you can only find an incident if a deploy happens to bracket
  # it (release filter) or it happens to be recent. start_time/end_time turn
  # the hours argument into a *duration* that can sit anywhere:
  #
  #   neither given        →  hours.ago .. now          (unchanged default)
  #   end_time + hours     →  end_time - hours .. end_time
  #   start_time + hours   →  start_time .. start_time + hours
  #   both given           →  absolute; hours ignored
  #
  # Retention checking changes meaning once windows float. The question is no
  # longer "is this duration longer than we keep?" but "does this window
  # overlap what we keep?" — a 24h window six months back is short and still
  # entirely gone. A window that starts before the cutoff is pulled forward
  # (with a note); one that *ends* before it is reported as expired rather
  # than returned empty, since an empty result reads as "no traffic then".
  #
  # Returns [time_range, note_or_nil]; raises WindowError on bad input.
  def resolve_window(args, hours_key, source, default: 24)
    start_at = parse_time(args["start_time"], "start_time")
    end_at = parse_time(args["end_time"], "end_time")
    cap = max_hours(source)
    requested = args[hours_key]&.to_i || default
    hours = requested.clamp(1, cap)
    notes = +""
    notes << "_Requested #{requested}h; this data is retained for #{cap}h (#{cap / 24}d), so the duration was reduced to #{hours}h._\n\n" if requested > cap

    now = Time.current
    if start_at && end_at
      # Absolute: hours says nothing, so don't let its clamp note mislead.
      notes = +""
    elsif end_at
      start_at = end_at - hours.hours
    elsif start_at
      end_at = start_at + hours.hours
    else
      end_at = now
      start_at = now - hours.hours
    end

    raise WindowError, "end_time must be after start_time" if end_at <= start_at

    if end_at > now
      end_at = now
      raise WindowError, "start_time is in the future" if end_at <= start_at
    end

    cutoff = now - cap.hours
    if end_at < cutoff
      raise WindowError,
        "That window ended #{((now - end_at) / 86_400).floor} days ago, but this data is retained for #{cap / 24} days. Nothing from it remains."
    end
    if start_at < cutoff
      notes << "_Window began before the #{cap / 24}d retention limit for this data; showing from #{cutoff.utc.strftime("%Y-%m-%d %H:%M")}Z._\n\n"
      start_at = cutoff
    end

    [start_at..end_at, notes.presence]
  end

  # How to describe a window in output. A window ending now is still "last
  # 24h" — that's how it was asked for — but an absolute one has to print its
  # bounds, since labelling a July window "last 24h" would be worse than
  # useless to an agent correlating against a timeline.
  def window_label(time_range)
    return nil unless time_range

    hours = ((time_range.end - time_range.begin) / 3600.0).round
    if (Time.current - time_range.end) < 120
      "last #{hours}h"
    else
      "#{time_range.begin.utc.strftime("%Y-%m-%d %H:%M")}Z → #{time_range.end.utc.strftime("%Y-%m-%d %H:%M")}Z (#{hours}h)"
    end
  end

  # compare_endpoint_performance measures its two windows from explicit
  # anchors (a release, or before/after timestamps) rather than from now, so
  # its hours are already durations and it needs the ceiling without the
  # window resolution. Returns [hours, note_or_nil].
  def clamp_duration_hours(args, key, source, default: 24)
    cap = max_hours(source)
    requested = args[key]&.to_i || default
    hours = requested.clamp(1, cap)
    return [hours, nil] unless requested > cap

    [hours, "_Requested #{requested}h for #{key}; this data is retained for #{cap}h (#{cap / 24}d), so it was reduced to #{hours}h._\n\n"]
  end

  def parse_time(value, field)
    return nil if value.blank?

    Time.parse(value.to_s).utc
  rescue ArgumentError
    raise WindowError, "Invalid #{field}: #{value.inspect}. Use ISO 8601, e.g. '2026-07-14T14:00:00Z'."
  end

  # Raw transactions age out well before the rollups do, so a window can have
  # solid percentiles and no individual rows left to quote. Keyed on where the
  # window *starts*, not how long it is — a short window far enough back is
  # just as expired as a long one.
  def raw_rows_expired?(time_range)
    time_range.begin < max_hours(:transactions).hours.ago
  end

  # Advertise the live ceiling in tools/list. These used to read a hardcoded
  # "max: 168" that no longer matched anything; interpolating keeps the schema
  # honest when retention settings change.
  def hours_description(source, label = "Number of hours to look back")
    cap = max_hours(source)
    "#{label} (default: 24, max: #{cap} — #{cap / 24}d, the retention window for this data). " \
    "This is the window's *duration*: on its own it means the last N hours, but combined with " \
    "end_time (or start_time) it positions the window anywhere inside retention."
  end

  # `name` has no uniqueness constraint (only slug does), so a display name can
  # legitimately match several projects. Picking one arbitrarily would silently
  # answer about the wrong project, so make the caller name a slug instead.
  def disambiguate(matches, raw)
    return matches.first if matches.size <= 1

    raise ProjectResolutionError,
      "#{raw.inspect} matches #{matches.size} projects by name. Use one of these slugs: " \
      "#{matches.map(&:slug).sort.join(", ")}"
  end

  # Applies the shared environment/release filters to an issue scope. Both are
  # "seen in" matches against issue_facets (maintained at ingest), never a
  # DISTINCT over events. project_id narrows the index lookup when the caller
  # named a project; without it the filter spans every project, same as the
  # rest of the tool.
  def apply_issue_facet_filters(issues, args, project_id)
    environment = args["environment"]
    release = args["release"]

    issues = issues.seen_in_environment(environment, project_id: project_id) if environment.present?
    issues = issues.seen_in_release(release, project_id: project_id) if release.present?
    issues
  end

  # Tool implementations
  def get_status(_args)
    snapshot = StorageStats.snapshot
    StorageStats.enqueue_refresh if snapshot.nil?
    render_text(format_status(snapshot, Ingest::Tuber.queue_depths))
  end

  def format_status(snapshot, queues)
    result = "## Splat Status\n\n"
    result += "- **Version:** #{Splat::VERSION}\n"
    result += "- **Environment:** #{Rails.env}\n\n"

    # Queues are live (tuber stats), independent of the storage snapshot —
    # show them even when the snapshot is still cold.
    result += format_queues(queues)

    if snapshot.nil?
      result += "_Storage snapshot not built yet (cold cache) — a refresh has been enqueued. Try again shortly._\n"
      return result
    end

    result += "- **Storage total:** #{human_size(snapshot[:total])}\n"
    result += "- **Stats collected:** #{snapshot[:collected_at]&.utc&.iso8601 || "unknown"} (refreshes every ~15 min)\n"
    # Table/index bytes and row counts come from the daily dbstat walk, not
    # the 15-min pass that carries them forward — so they get their own
    # timestamp rather than inheriting collected_at's freshness claim.
    if (deep = snapshot[:deep_collected_at])
      result += "- **Table sizes from:** #{deep.utc.iso8601} (deep dbstat pass, daily)\n"
    end
    result += "\n"

    result += format_retention_settings
    result += format_storage_groups(snapshot)

    data_span = snapshot[:data_span]
    if data_span&.any?
      result += "### Data span (retention)\n\n"
      result += "| Table | Oldest | Newest | Span |\n|---|---|---|---:|\n"
      data_span.each do |d|
        oldest = d[:oldest]&.utc&.iso8601 || "—"
        newest = d[:newest]&.utc&.iso8601 || "—"
        span = d[:days] ? "#{d[:days]} days" : "—"
        result += "| #{d[:name]} | #{oldest} | #{newest} | #{span} |\n"
      end
      result += "\n"
    end

    compression = snapshot[:compression]
    if compression&.any?
      total_saved = compression.sum { |c| c[:saved_bytes] }
      result += "### Compression — ~#{human_size(total_saved)} saved\n\n"
      result += "| Segment | Rows | Ratio | Stored | Saved |\n|---|---:|---:|---:|---:|\n"
      compression.each do |c|
        result += "| #{c[:name]} | #{c[:rows]} | #{c[:ratio].round(1)}× | #{human_size(c[:stored_bytes])} | #{human_size(c[:saved_bytes])} |\n"
      end
      result += format_uncompressed_rows(snapshot)
      result += "\n"
    end

    result
  end

  # Per-table sizes, split into data vs index bytes. The split is the whole
  # point: a table that's mostly index wants indexes dropped, one that's
  # mostly data wants compression, and the combined total can't tell them
  # apart. `indexes` is absent from snapshots written before it was
  # collected, so every read of it tolerates nil.
  def format_storage_groups(snapshot)
    result = "### Storage by database\n\n"
    Array(snapshot[:groups]).each do |group|
      group_total = group[:tables].sum { |t| t[:total_bytes] }
      result += "**#{group[:name]}** — #{human_size(group_total)}\n\n"
      result += "| Table | Rows | Data | Indexes | Total |\n|---|---:|---:|---:|---:|\n"
      group[:tables].each do |t|
        result += "| #{t[:name]} | #{t[:row_estimate]} | #{human_size(t[:table_bytes])} | " \
                  "#{human_size(t[:index_bytes])} | #{human_size(t[:total_bytes])} |\n"
      end
      result += "\n"
    end
    result + format_largest_indexes(snapshot)
  end

  # The biggest individual indexes across every DB. Answers "which of these
  # seven indexes is worth dropping?" — a per-table index total can't, since
  # it hides one 1 GB index among six small ones.
  def format_largest_indexes(snapshot, limit: 15)
    indexes = Array(snapshot[:groups]).flat_map { |group|
      group[:tables].flat_map do |t|
        Array(t[:indexes]).map { |idx| idx.merge(table: t[:name]) }
      end
    }.reject { |idx| idx[:bytes].to_i.zero? }.sort_by { |idx| -idx[:bytes].to_i }

    return "" if indexes.empty?

    result = "### Largest indexes (top #{limit})\n\n"
    result += "| Index | Table | Size |\n|---|---|---:|\n"
    indexes.first(limit).each do |idx|
      result += "| #{idx[:name]} | #{idx[:table]} | #{human_size(idx[:bytes])} |\n"
    end
    result + "\n"
  end

  # The configured retention windows. get_status already reports the observed
  # data span, but observed < configured whenever a table is younger than its
  # window — so the span alone can't tell you what the window actually is,
  # nor how much growth is still ahead.
  def format_retention_settings
    s = Setting.instance
    rows = [
      ["Events", s.events_data_retention_days],
      ["Transactions", s.transactions_data_retention_days],
      ["Spans / span trees", s.spans_data_retention_days],
      ["Logs", s.logs_data_retention_days],
      ["Histograms + hourly stats", s.histograms_retention_days]
    ]
    result = "### Retention settings (configured)\n\n"
    result += "| Data | Keep for |\n|---|---:|\n"
    rows.each { |name, days| result += "| #{name} | #{days} days |\n" }
    result + "\n"
  rescue => e
    Rails.logger.warn("MCP get_status: retention settings unavailable: #{e.class}: #{e.message}")
    ""
  end

  # Payload-bearing tables holding uncompressed data, listed alongside the
  # compressed segments. Without these rows the compression table is a list of
  # successes and the gaps are invisible — you'd have to notice an absence to
  # spot the biggest uncompressed table in the system.
  #
  # `spans` is legacy-only (frozen at the 1.7.0 span_trees cutover) and ages
  # out with retention. `transactions` stays plain-JSON by design: a
  # measurements_blob compression was drafted and rejected in favor of
  # slimming what gets written (query_patterns only, one example per
  # pattern — the rest was redundant with promoted columns). Rows from
  # before the slim carry the fat JSON until retention ages them out, so
  # this table's size overstates the steady state until then.
  UNCOMPRESSED_TABLES = {
    "transactions" => "Transactions (plain-JSON measurements, slimmed at ingest)",
    "spans" => "Spans (legacy, frozen at 1.7.0 cutover)"
  }.freeze

  def format_uncompressed_rows(snapshot)
    sizes = Array(snapshot[:groups]).flat_map { |g| g[:tables] }
      .each_with_object({}) { |t, h| h[t[:name]] = t }

    UNCOMPRESSED_TABLES.filter_map { |table, label|
      t = sizes[table]
      next if t.nil? || t[:total_bytes].to_i.zero?
      "| #{label} | #{t[:row_estimate]} | — | #{human_size(t[:table_bytes])} | not compressed |\n"
    }.join
  end

  def format_queues(queues)
    return "### Queues\n\n_Tuber unreachable._\n\n" if queues.blank?

    result = "### Queues (live)\n\n"
    result += "| Tube | Ready | Reserved | Buried |\n|---|---:|---:|---:|\n"
    queues.each do |name, d|
      result += "| #{name} | #{d[:ready]} | #{d[:reserved]} | #{d[:buried]} |\n"
    end
    result + "\n"
  end

  def human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i)
  end

  def list_monitors(args)
    project_id = resolve_project_id(args)

    monitors = CronMonitor.includes(:project).by_slug
    monitors = monitors.where(project_id: project_id) if project_id
    monitors = monitors.where(state: args["state"]) if args["state"].present?
    monitors = monitors.to_a

    if monitors.empty?
      # structured: {} even here — a tool that declares an outputSchema has to
      # carry structuredContent on every success, empty result included.
      return render_text(
        "No monitors#{args["state"].present? ? " in state '#{args["state"]}'" : " registered"}. Monitors auto-register when a service sends a Sentry Crons check-in envelope to its project DSN.",
        structured: {monitors: []}
      )
    end

    lines = ["# Check-In Monitors (#{monitors.size})", ""]
    monitors.each do |m|
      lines << "## #{m.slug} — #{m.state}"
      lines << "- **Project:** #{m.project&.name}"
      schedule = m.schedule_description
      # A crontab means nothing without the zone it's read in — without this a
      # monitor checking in dead on time looks 14 hours late.
      schedule += " #{m.timezone}" if m.timezone.present?
      schedule += " (+#{m.checkin_margin}m margin)" if m.checkin_margin.to_i.positive?
      lines << "- **Schedule:** #{schedule}"
      lines << "- **Max runtime:** #{m.max_runtime}m" if m.max_runtime.to_i.positive?
      lines << if m.last_checkin_at
        "- **Last check-in:** #{m.last_checkin_at.iso8601} (#{time_ago_in_words(m.last_checkin_at)} ago, status: #{m.last_status})"
      else
        "- **Last check-in:** never"
      end
      lines << "- **In progress since:** #{m.in_progress_since.iso8601}" if m.in_progress_since
      lines << "- **Last duration:** #{m.last_duration.round(2)}s" if m.last_duration
      lines << "- **Environment:** #{m.environment}" if m.environment.present?
      lines << ""
    end

    structured = monitors.map do |m|
      {
        slug: m.slug,
        state: m.state,
        project: m.project&.name,
        schedule: m.schedule_description,
        timezone: m.timezone,
        checkin_margin_minutes: m.checkin_margin,
        max_runtime_minutes: m.max_runtime,
        last_checkin_at: m.last_checkin_at&.utc&.iso8601,
        last_status: m.last_status,
        last_duration_seconds: m.last_duration,
        in_progress_since: m.in_progress_since&.utc&.iso8601,
        environment: m.environment
      }
    end

    render_text(lines.join("\n"), structured: {monitors: structured})
  end

  def list_recent_issues(args)
    status = args["status"] || "open"
    limit = (args["limit"]&.to_i || 20).clamp(1, 100)

    project_id = resolve_project_id(args)

    issues = Issue.includes(:project).recent
    issues = issues.where(project_id: project_id) if project_id
    issues = issues.where(status: status) unless status == "all"
    issues = apply_issue_facet_filters(issues, args, project_id)
    issues = issues.limit(limit).to_a

    text = format_issues_list(issues, status)

    render_text(text, structured: {issues: issues.map { |i| issue_out(i) }})
  end

  def search_issues(args)
    query = args["query"]
    status = args["status"]
    exception_type = args["exception_type"]
    limit = (args["limit"]&.to_i || 20).clamp(1, 100)

    project_id = resolve_project_id(args)

    issues = Issue.includes(:project).recent
    issues = issues.where(project_id: project_id) if project_id
    issues = issues.matching_text(query) if query.present?
    issues = issues.where(status: status) if status.present?
    issues = issues.where(exception_type: exception_type) if exception_type.present?
    issues = apply_issue_facet_filters(issues, args, project_id)
    issues = issues.limit(limit).to_a

    text = format_issues_list(issues)

    render_text(text, structured: {issues: issues.map { |i| issue_out(i) }})
  end

  def get_issue(args)
    issue = Issue.includes(:project).find(args["issue_id"])
    recent_event = issue.events.order(timestamp: :desc).first

    text = format_issue_detail(issue, recent_event)

    render_text(text)
  end

  def get_issue_events(args)
    issue = Issue.find(args["issue_id"])
    limit = (args["limit"]&.to_i || 10).clamp(1, 50)
    events = issue.events.order(timestamp: :desc).limit(limit)

    text = format_issue_events(issue, events)

    render_text(text)
  end

  def get_event(args)
    event = Event.includes(:issue, :project).find_by!(event_id: args["event_id"])

    text = format_event_detail(event)

    render_text(text)
  end

  def search_logs(args)
    time_range, window_note = resolve_window(args, "time_range_hours", :logs)
    limit = (args["limit"]&.to_i || 50).clamp(1, 200)

    project_id = resolve_project_id(args)

    logs = Log.where(timestamp: time_range).recent
    logs = logs.where(project_id: project_id) if project_id
    logs = logs.search_text(args["query"]) if args["query"].present?
    logs = logs.by_level(args["level"]) if args["level"].present? && Log.levels.key?(args["level"])
    logs = logs.by_logger(args["logger"]) if args["logger"].present?
    logs = logs.for_trace(args["trace_id"]).reorder(timestamp: :desc) if args["trace_id"].present?
    logs = logs.by_environment(args["environment"]) if args["environment"].present?
    logs = logs.by_release(args["release"]) if args["release"].present?
    logs = logs.limit(limit)

    render_text("#{window_note}#{format_logs_list(logs.to_a, window_label(time_range))}")
  end

  def get_log(args)
    log = Log.find_by(log_id: args["log_id"])
    return render_error("Log not found: #{args["log_id"]}") unless log

    render_text(format_log_detail(log))
  end

  def get_trace_logs(args)
    trace_id = args["trace_id"]
    return render_error("trace_id is required") if trace_id.blank?

    limit = (args["limit"]&.to_i || 100).clamp(1, 500)
    logs = Log.for_trace(trace_id).limit(limit).to_a

    render_text(format_logs_list(logs, nil, header: "Logs for trace #{trace_id}"))
  end

  def get_transaction_stats(args)
    endpoint = args["endpoint"]
    environment = args["environment"].presence
    time_range, window_note = resolve_window(args, "time_range_hours", :rollup)
    limit = (args["limit"]&.to_i || 10).clamp(1, 50)

    project_id = resolve_project_id(args)

    # total_count comes from the same hourly rollups as the percentiles, not
    # from a COUNT over raw transactions. Raw rows and rollups have separate
    # retention windows (transactions_data_retention_days vs
    # histograms_retention_days), so counting raw rows reported a count and a
    # p95 describing different populations once the shorter window elapsed.
    if endpoint.present?
      ep_stats = Transaction.percentiles_for_endpoint(endpoint, time_range, project_id: project_id, environment: environment)
      percentiles = {
        avg: ep_stats["avg_duration"]&.to_f || 0,
        p50: ep_stats["p50_duration"]&.to_f || 0,
        p95: ep_stats["p95_duration"]&.to_f || 0,
        p99: ep_stats["p99_duration"]&.to_f || 0,
        min: ep_stats["min_duration"]&.to_f || 0,
        max: ep_stats["max_duration"]&.to_f || 0
      }
      total_count = ep_stats["count"].to_i
    else
      percentiles = Transaction.percentiles(time_range, project_id: project_id, environment: environment)
      total_count = percentiles[:count].to_i
    end

    top_endpoints = Transaction.stats_by_endpoint_with_impact(time_range, project_id: project_id, environment: environment, limit: limit)

    text = format_transaction_stats(percentiles, top_endpoints, total_count, window_label(time_range), endpoint)

    structured = {
      window: window_out(time_range),
      endpoint: endpoint.presence,
      environment: environment,
      total_count: total_count,
      percentiles: percentiles.slice(:avg, :p50, :p95, :p99, :min, :max).transform_values { |v| v&.to_f },
      top_endpoints: top_endpoints.map do |row|
        {
          transaction_name: row["transaction_name"],
          time_spent: row["time_spent"]&.to_f,
          avg_duration: row["avg_duration"]&.to_f,
          p95_duration: row["p95_duration"]&.to_f,
          count: row["count"].to_i
        }
      end
    }

    render_text("#{window_note}#{text}", structured: structured)
  end

  def search_slow_transactions(args)
    min_duration_ms = [args["min_duration_ms"]&.to_i || 1000, 0].max
    max_duration_ms = args["max_duration_ms"]&.to_i
    max_duration_ms = nil unless max_duration_ms&.positive?
    endpoint = args["endpoint"]
    http_status = args["http_status"]
    http_method = args["http_method"]
    environment = args["environment"]
    release = args["release"]
    time_range, window_note = resolve_window(args, "time_range_hours", :transactions)
    limit = (args["limit"]&.to_i || 20).clamp(1, 100)

    tags = args["tags"]
    tags = nil unless tags.is_a?(Hash) && tags.any?
    if tags
      bad_key = tags.keys.find { |k| !k.is_a?(String) || k !~ /\A[a-zA-Z0-9_.-]+\z/ }
      return render_error("Invalid tag key: #{bad_key.inspect}. Tag keys may contain letters, digits, underscore, dot and hyphen.") if bad_key
      tags = tags.transform_values(&:to_s)
    end

    rows = Transaction.slow(
      threshold_ms: min_duration_ms,
      max_duration_ms: max_duration_ms,
      time_range: time_range,
      project_id: resolve_project_id(args),
      transaction_name: endpoint,
      http_status: http_status,
      http_method: http_method,
      environment: environment,
      release: release,
      tags: tags,
      limit: limit
    )

    project_names = Project.where(id: rows.map(&:project_id).compact.uniq).pluck(:id, :name).to_h
    rows = rows.map do |r|
      h = r.attributes
      h["project_name"] = project_names[r.project_id]
      h
    end

    text = format_slow_transactions(rows, min_duration_ms, max_duration_ms, window_label(time_range))

    render_text("#{window_note}#{text}")
  end

  def get_transaction(args)
    transaction = find_transaction(args["transaction_id"], trace_id: args["trace_id"], project_id: resolve_project_id(args))
    # trace_id is promoted onto the transaction row; the detail output uses it
    # to point an agent at get_trace_logs (mirrors the transaction→logs link
    # in the web UI).
    render_text(format_transaction_detail(transaction, transaction.trace_id))
  end

  def get_transaction_spans(args)
    transaction = find_transaction(args["transaction_id"], trace_id: args["trace_id"], project_id: resolve_project_id(args))
    op_filter = args["op_filter"].to_s.strip
    limit = (args["limit"]&.to_i || 100).clamp(1, 1000)

    # Materialize a hash per span; duration_ms is a computed method, not
    # a column, so .attributes alone would miss it.
    all_spans = Span.for_transaction(
      transaction.transaction_id,
      project_id: transaction.project_id,
      near_timestamp: transaction.timestamp
    ).map { |s| s.attributes.merge("duration_ms" => s.duration_ms) }

    filtered = op_filter.present? ? all_spans.select { |s| s["op"].to_s.start_with?(op_filter) } : all_spans

    render_text(format_transaction_spans(transaction, all_spans, filtered, op_filter, limit))
  end

  # Accepts an internal id, a Sentry transaction UUID, or — closing the gap
  # from a log to its request — a trace_id. trace_id can't be sniffed from the
  # string (it's hex like transaction_id), so it's a separate argument rather
  # than a third branch on format. It's promoted onto the transaction row and
  # indexed as [project_id, trace_id]; without project_id that index can't be
  # used for a prefix lookup, so scope the scan by timestamp ordering and take
  # the most recent match. A trace holds at most one server transaction per
  # service, so this is a lookup rather than a genuine ambiguity.
  def find_transaction(id, trace_id: nil, project_id: nil)
    if trace_id.present?
      scope = Transaction.includes(:project).where(trace_id: trace_id.to_s)
      scope = scope.where(project_id: project_id) if project_id
      found = scope.order(timestamp: :desc).first
      raise ActiveRecord::RecordNotFound, "No transaction found for trace_id #{trace_id}" unless found
      return found
    end

    id_str = id.to_s
    if id_str.blank?
      raise ActiveRecord::RecordNotFound, "Supply either transaction_id or trace_id"
    elsif id_str.match?(/\A\d+\z/)
      Transaction.includes(:project).find(id_str)
    else
      Transaction.includes(:project).find_by!(transaction_id: id_str)
    end
  end

  def get_endpoint_summary(args)
    endpoint = args["endpoint"]
    environment = args["environment"]
    release = args["release"]
    # A release filter drops percentiles_for_endpoint onto its raw fallback, so
    # the window can only reach as far back as raw transactions survive.
    time_range, window_note = resolve_window(args, "hours", release.present? ? :transactions : :rollup)
    project_id = resolve_project_id(args)

    stats = Transaction.percentiles_for_endpoint(
      endpoint, time_range, project_id: project_id, environment: environment, release: release
    )
    total_count = stats["count"].to_i
    return render_text("No transactions found for endpoint '#{endpoint}' with the specified filters.") if total_count.zero?

    percentiles = {
      avg: stats["avg_duration"]&.to_f || 0,
      p50: stats["p50_duration"]&.to_f || 0,
      p95: stats["p95_duration"]&.to_f || 0,
      p99: stats["p99_duration"]&.to_f || 0,
      min: stats["min_duration"]&.to_f || 0,
      max: stats["max_duration"]&.to_f || 0
    }
    db_percentiles =
      if stats["avg_db_time"]
        {avg: stats["avg_db_time"].to_f, p95: stats["p95_db_time"]&.to_f || 0}
      end
    view_percentiles =
      if stats["avg_view_time"]
        {avg: stats["avg_view_time"].to_f, p95: stats["p95_view_time"]&.to_f || 0}
      end

    slowest_request = endpoint_extreme_row(endpoint, time_range, environment, release, :desc, project_id)
    fastest_request = endpoint_extreme_row(endpoint, time_range, environment, release, :asc, project_id)

    text = format_endpoint_summary(
      endpoint, total_count, window_label(time_range), environment, release,
      percentiles, db_percentiles, view_percentiles,
      slowest_request, fastest_request
    )
    # The percentiles above come from the rollups, which outlive raw rows; say
    # so rather than just omitting the sample-requests section.
    if raw_rows_expired?(time_range) && (slowest_request.nil? || fastest_request.nil?)
      text += "\n_Individual requests are retained for #{max_hours(:transactions) / 24}d, so no sample requests are available across this window. Percentiles above are from the hourly rollups._\n"
    end

    render_text("#{window_note}#{text}")
  end

  def find_n_plus_one_endpoints(args)
    time_range, window_note = resolve_window(args, "time_range_hours", :rollup)
    environment = args["environment"]
    limit = (args["limit"]&.to_i || 20).clamp(1, 100)

    rows = Transaction.endpoints_by_n_plus_one(
      time_range, project_id: resolve_project_id(args), environment: environment, limit: limit
    )

    text = format_n_plus_one_endpoints(rows, window_label(time_range), environment)

    structured = {
      window: window_out(time_range),
      environment: environment,
      endpoints: rows.map do |r|
        {
          transaction_name: r["transaction_name"],
          n_plus_one_count: r["n_plus_one_count"].to_i,
          total_count: r["total_count"].to_i,
          n_plus_one_pct: r["n_plus_one_pct"]&.to_f,
          avg_queries: r["avg_queries"]&.to_f,
          max_queries: r["max_queries"]&.to_i,
          avg_duration: r["avg_duration"]&.to_f,
          p95_duration: r["p95_duration"]&.to_f,
          n_plus_one_time_ms: r["n_plus_one_time"].to_i,
          avg_n_plus_one_time_ms: r["avg_n_plus_one_time"]&.to_f
        }
      end
    }

    render_text("#{window_note}#{text}", structured: structured)
  end

  def get_endpoint_timeseries(args)
    endpoint = args["endpoint"]
    environment = args["environment"]
    release = args["release"]
    time_range, window_note = resolve_window(args, "hours", release.present? ? :transactions : :rollup)
    requested_buckets = (args["buckets"]&.to_i || 24).clamp(4, 168)

    series = Transaction.time_series_for_endpoint(
      endpoint, time_range, project_id: resolve_project_id(args),
      bucket_count: requested_buckets, environment: environment, release: release
    )
    # Ask the same helper the reader used rather than re-dividing hours by
    # buckets — snapping to whole hours means the effective width and count can
    # differ from what was requested, and the row labels have to match the data.
    bucket_seconds, buckets = Transaction.bucketing_for(time_range, requested_buckets)

    text = format_endpoint_timeseries(
      endpoint, series, window_label(time_range), buckets, bucket_seconds, requested_buckets,
      environment, release, time_range.begin
    )

    structured = {
      endpoint: endpoint,
      window: window_out(time_range),
      environment: environment,
      release: release,
      bucket_seconds: bucket_seconds,
      buckets: buckets,
      requested_buckets: requested_buckets,
      # Same derivation the table uses: the reader returns a bucket *index*,
      # so wall-clock start is the window origin plus index × width.
      series: series.map do |b|
        {
          bucket_start: (time_range.begin + (b["bucket"] * bucket_seconds)).utc.iso8601,
          count: b["count"].to_i,
          p50: b["p50"]&.to_f,
          p95: b["p95"]&.to_f,
          p99: b["p99"]&.to_f
        }
      end
    }

    render_text("#{window_note}#{text}", structured: structured)
  end

  def endpoint_extreme_row(endpoint, time_range, environment, release, direction, project_id = nil)
    scope = Transaction.where(transaction_name: endpoint, timestamp: time_range)
    scope = scope.where(project_id: project_id) if project_id
    scope = scope.where(environment: environment) if environment.present?
    scope = scope.where(release: release) if release.present?
    row = scope.order(duration: (direction == :desc) ? :desc : :asc).limit(1).first
    row && {"id" => row.id, "duration" => row.duration, "db_time" => row.db_time,
            "view_time" => row.view_time, "timestamp" => row.timestamp}
  end

  def get_transactions_by_endpoint(args)
    endpoint = args["endpoint"]
    limit = (args["limit"]&.to_i || 20).clamp(1, 100)
    # Lists individual rows, so it's bounded by raw transaction retention.
    time_range, window_note = resolve_window(args, "hours", :transactions)
    environment = args["environment"]
    release = args["release"]

    project_id = resolve_project_id(args)

    transactions = Transaction.includes(:project)
      .where(transaction_name: endpoint)
      # Was a bare lower bound; an upper one is required now that the window
      # can end somewhere other than "now".
      .where(timestamp: time_range)
      .order(timestamp: :desc)
      .limit(limit)

    transactions = transactions.where(project_id: project_id) if project_id
    transactions = transactions.where(environment: environment) if environment.present?
    transactions = transactions.where(release: release) if release.present?

    text = format_transactions_by_endpoint(transactions, endpoint, window_label(time_range), environment, release)

    render_text("#{window_note}#{text}")
  end

  def compare_endpoint_performance(args)
    endpoint = args["endpoint"]
    before_release = args["before_release"]
    after_release = args["after_release"]
    before_timestamp = args["before_timestamp"]
    after_timestamp = args["after_timestamp"]
    # Both arms collect raw transaction rows, so both windows sit on the raw
    # retention clock regardless of which comparison mode is used.
    hours_before, before_note = clamp_duration_hours(args, "hours_before", :transactions)
    hours_after, after_note = clamp_duration_hours(args, "hours_after", :transactions)
    environment = args["environment"]
    project_id = resolve_project_id(args)

    # Validate input - either release-based or timestamp-based comparison
    if before_release.present? && after_release.present?
      # Version-based comparison
      before_transactions = get_transactions_by_filters(endpoint, hours_before, environment, before_release, project_id)
      after_transactions = get_transactions_by_filters(endpoint, hours_after, environment, after_release, project_id)
      comparison_type = "version"
      before_label = "Version #{before_release}"
      after_label = "Version #{after_release}"
    elsif before_timestamp.present? && after_timestamp.present?
      # Timestamp-based comparison
      before_time = Time.parse(before_timestamp)
      after_time = Time.parse(after_timestamp)

      before_transactions = get_transactions_by_time_range(endpoint, before_time - hours_before.hours, before_time, environment, project_id)
      after_transactions = get_transactions_by_time_range(endpoint, after_time, after_time + hours_after.hours, environment, project_id)
      comparison_type = "timestamp"
      before_label = "Before #{before_timestamp}"
      after_label = "After #{after_timestamp}"
    else
      return render_error("Please provide either both before_release/after_release OR both before_timestamp/after_timestamp for comparison.")
    end

    text = format_performance_comparison(
      endpoint, comparison_type, before_label, after_label,
      before_transactions, after_transactions
    )

    render_text("#{before_note}#{after_note}#{text}")
  rescue ArgumentError
    render_error("Invalid timestamp format. Please use ISO format (e.g., '2025-10-21T03:00:00Z')")
  end

  def resolve_issue(args)
    issue = Issue.find(args["issue_id"])
    issue.resolved!
    render_text("✅ Issue ##{issue.id} marked as resolved")
  end

  def ignore_issue(args)
    issue = Issue.find(args["issue_id"])
    issue.ignored!
    render_text("🔕 Issue ##{issue.id} marked as ignored")
  end

  def reopen_issue(args)
    issue = Issue.find(args["issue_id"])
    issue.open!
    render_text("🔓 Issue ##{issue.id} reopened")
  end

  # Helper methods for new tools
  def calculate_percentiles(values)
    return {} if values.empty?

    {
      avg: values.sum / values.size,
      p50: values[values.size * 0.5],
      p95: values[values.size * 0.95],
      p99: values[values.size * 0.99],
      min: values.first,
      max: values.last
    }
  end

  # Returns a sorted array of durations from the transactions DB, ready for percentile calc.
  def get_transactions_by_filters(endpoint, hours, environment, release, project_id = nil)
    durations_for(
      endpoint,
      hours.hours.ago..Time.current,
      environment: environment,
      release: release,
      project_id: project_id
    )
  end

  def get_transactions_by_time_range(endpoint, start_time, end_time, environment, project_id = nil)
    durations_for(endpoint, start_time..end_time, environment: environment, project_id: project_id)
  end

  def durations_for(endpoint, time_range, environment: nil, release: nil, project_id: nil)
    scope = Transaction.where(transaction_name: endpoint, timestamp: time_range)
    scope = scope.where(project_id: project_id) if project_id
    scope = scope.where(environment: environment) if environment.present?
    scope = scope.where(release: release) if release.present?
    scope.pluck(:duration).sort
  end

  def format_logs_list(logs, window, header: nil)
    if logs.empty?
      # get_trace_logs passes no window (a trace isn't time-scoped).
      return window ? "No logs found in #{window}." : "No logs found."
    end

    project_names = Project.where(id: logs.map(&:project_id).uniq).pluck(:id, :name).to_h
    title = header || "Logs (#{window})"
    result = "## #{title}\n\nShowing #{logs.size} log(s):\n\n"
    logs.each do |log|
      result += "- **#{log.level.to_s.upcase}** #{log.timestamp.utc.strftime("%Y-%m-%d %H:%M:%S")} "
      result += "[#{project_names[log.project_id] || log.project_id}] #{log.body}\n"
      meta = []
      meta << "logger=#{log.logger_name}" if log.logger_name.present?
      meta << "env=#{log.environment}" if log.environment.present?
      # duration_ms and release are already on the row. Omitting them meant a
      # round-trip to get_log per line to answer "was this slow?" — and a wall
      # of identical fast responses (load shedding, say) reads as ordinary
      # traffic until you open one.
      meta << "dur=#{log.duration_ms.round}ms" if log.duration_ms.present?
      meta << "release=#{log.release}" if log.release.present?
      meta << "trace=#{log.trace_id}" if log.trace_id.present?
      meta << "log_id=#{log.log_id}"
      result += "  #{meta.join(" · ")}\n"
    end
    result
  end

  def format_log_detail(log)
    result = "## Log #{log.log_id}\n\n"
    result += "- **Level:** #{log.level}\n"
    result += "- **Time:** #{log.timestamp.utc.iso8601}\n"
    result += "- **Body:** #{log.body}\n"
    result += "- **Logger:** #{log.logger_name}\n" if log.logger_name.present?
    result += "- **Environment:** #{log.environment}\n" if log.environment.present?
    result += "- **Release:** #{log.release}\n" if log.release.present?
    result += "- **Server:** #{log.server_name}\n" if log.server_name.present?
    result += "- **Source:** #{log.source}\n" if log.source.present?
    result += "- **Trace:** #{log.trace_id}\n" if log.trace_id.present?
    result += "- **Span:** #{log.span_id}\n" if log.span_id.present?

    attrs = log.payload_attributes
    if attrs.present? && attrs.any?
      result += "\n### Attributes\n\n"
      attrs.each do |k, v|
        val = (v.is_a?(Hash) && v.key?("value")) ? v["value"] : v
        result += "- **#{k}:** #{val}\n"
      end
    end
    result
  end

  # Every tool returns through one of these two. Both produce a successful
  # JSON-RPC response; the difference is the isError flag inside the result.
  # The markdown is the answer; `structured` is an optional machine-readable
  # copy for the tools that declare an outputSchema (SplatMcpServer.output_schemas).
  # Both travel together — nothing is moved out of the text to make room for it.
  def render_text(text, structured: nil)
    ::MCP::Tool::Response.new([{type: "text", text: text}], structured_content: structured)
  end

  # The window as the caller should read it back: the range actually queried
  # after retention clamping, plus the same label the markdown header carries.
  def window_out(time_range)
    {
      start: time_range.begin.utc.iso8601,
      end: time_range.end.utc.iso8601,
      label: window_label(time_range)
    }
  end

  def issue_out(issue)
    {
      id: issue.id,
      title: issue.title,
      exception_type: issue.exception_type,
      status: issue.status,
      count: issue.count,
      first_seen: issue.first_seen&.utc&.iso8601,
      last_seen: issue.last_seen&.utc&.iso8601,
      project: issue.project&.name
    }
  end

  # A tool-level failure, not a protocol one. This used to be a JSON-RPC
  # -32602 with an HTTP 400, which is what the spec reserves for a request the
  # *client* got wrong — a malformed frame, an unknown method. But "unknown
  # project: boko" is something the model got wrong and can fix on the next
  # call, and it can only do that if it's shown the message. Under -32602 most
  # clients surface a transport failure to the user and never hand the text
  # back to the model. isError does.
  def render_error(message)
    ::MCP::Tool::Response.new([{type: "text", text: message}], error: true)
  end

  # Formatting helpers
  def format_issues_list(issues, status_filter = nil)
    if issues.empty?
      status_text = status_filter ? " with status '#{status_filter}'" : ""
      return "No issues found#{status_text}."
    end

    result = "## Recent Issues\n\n"
    result += "Showing #{issues.size} issue(s):\n\n"

    issues.each do |issue|
      result += "**Issue ##{issue.id}** - #{issue.title}\n"
      result += "  - Exception Type: #{issue.exception_type}\n"
      result += "  - Status: #{issue.status}\n"
      result += "  - Count: #{issue.count} occurrence(s)\n"
      result += "  - Last Seen: #{issue.last_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "  - Project: #{issue.project.name}\n\n"
    end

    result
  end

  def format_issue_detail(issue, recent_event)
    result = "## Issue ##{issue.id}: #{issue.title}\n\n"
    result += "**Exception Type:** #{issue.exception_type}\n"
    result += "**Status:** #{issue.status}\n"
    result += "**Occurrences:** #{issue.count}\n"
    result += "**First Seen:** #{issue.first_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
    result += "**Last Seen:** #{issue.last_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
    result += "**Project:** #{issue.project.name}\n\n"

    if recent_event&.payload
      result += "### Most Recent Stack Trace\n\n"
      frames = recent_event.payload.dig("exception", "values", 0, "stacktrace", "frames")

      if frames.present?
        result += "```\n"
        frames.reverse_each do |frame|
          filename = frame["filename"] || "unknown"
          lineno = frame["lineno"] || "?"
          function = frame["function"] || "unknown"
          result += "  at #{function} (#{filename}:#{lineno})\n"
        end
        result += "```\n"
      else
        result += "No stack trace available for this event.\n"
      end
    else
      result += "No events found for this issue.\n"
    end

    result
  end

  def format_issue_events(issue, events)
    result = "## Events for Issue ##{issue.id}: #{issue.title}\n\n"
    result += "Showing #{events.size} most recent event(s):\n\n"

    if events.empty?
      result += "No events found for this issue.\n"
    else
      events.each_with_index do |event, index|
        result += "### Event #{index + 1}\n"
        result += "**Event ID:** #{event.event_id}\n"
        result += "**Timestamp:** #{event.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
        result += "**Environment:** #{event.environment}\n" if event.environment.present?
        result += "**Server:** #{event.server_name}\n" if event.server_name.present?
        result += "\n"
      end
    end

    result
  end

  def format_event_detail(event)
    result = "## Event: #{event.event_id}\n\n"
    result += "**Timestamp:** #{event.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
    result += "**Project:** #{event.project.name}\n"
    result += "**Environment:** #{event.environment}\n" if event.environment
    result += "**Release:** #{event.release}\n" if event.release
    result += "**Server:** #{event.server_name}\n" if event.server_name
    result += "**Platform:** #{event.platform}\n" if event.platform
    result += "**Issue:** ##{event.issue.id} - #{event.issue.title}\n" if event.issue
    # The trace ties this error to the request that threw it. Mirrors the hint
    # get_transaction already prints, so the correlation is discoverable from
    # either end.
    if event.trace_id.present?
      result += "**Trace:** #{event.trace_id}\n"
      if (txn = event.related_transaction)
        result += "_Thrown during transaction ##{txn.id} (#{txn.transaction_name}, #{txn.duration}ms) — " \
                  "call `get_transaction` with id #{txn.id} for its span waterfall._\n"
      end
      result += "_Call `get_trace_logs` with this trace_id for the correlated log lines._\n"
    end
    result += "\n"

    # Exception details
    exception_details = event.exception_details
    if exception_details[:type] || exception_details[:value]
      result += "### Exception\n\n"
      result += "**Type:** #{exception_details[:type]}\n" if exception_details[:type]
      result += "**Message:** #{exception_details[:value]}\n" if exception_details[:value]
      result += "\n"
    end

    # Stack trace
    if exception_details[:stacktrace]&.dig("frames")
      result += "### Stack Trace\n\n"
      result += "```\n"
      exception_details[:stacktrace]["frames"].reverse_each do |frame|
        filename = frame["filename"] || "unknown"
        lineno = frame["lineno"] || "?"
        function = frame["function"] || "unknown"
        result += "  at #{function} (#{filename}:#{lineno})\n"
      end
      result += "```\n\n"
    end

    # Request details
    request_data = event.request
    if request_data.present?
      result += "### Request\n\n"
      result += "**URL:** #{request_data["url"]}\n" if request_data["url"]
      result += "**Method:** #{request_data["method"]}\n" if request_data["method"]
      result += "**Query String:** #{request_data["query_string"]}\n" if request_data["query_string"].present?

      # Request ID (common in Rails apps)
      if request_data["headers"]
        headers = request_data["headers"]
        request_id = headers["X-Request-Id"] || headers["x-request-id"] || headers["REQUEST_ID"]
        result += "**Request ID:** #{request_id}\n" if request_id
      end

      result += "\n"
    end

    # User context (sanitized)
    user_data = event.user
    if user_data.present?
      result += "### User Context\n\n"
      result += "**ID:** #{user_data["id"]}\n" if user_data["id"]
      result += "**Email:** #{user_data["email"]}\n" if user_data["email"]
      result += "**IP:** #{user_data["ip_address"]}\n" if user_data["ip_address"]
      result += "\n"
    end

    # Tags
    tags = event.tags
    if tags.present?
      result += "### Tags\n\n"
      tags.each do |key, value|
        result += "- **#{key}:** #{value}\n"
      end
      result += "\n"
    end

    # Breadcrumbs (last 10)
    breadcrumbs = event.breadcrumbs
    if breadcrumbs.present? && breadcrumbs.any?
      result += "### Breadcrumbs (Last #{[breadcrumbs.size, 10].min})\n\n"
      breadcrumbs.last(10).each do |crumb|
        timestamp = crumb["timestamp"] ? Time.at(crumb["timestamp"]).strftime("%H:%M:%S") : "?"
        category = crumb["category"] || "default"
        message = crumb["message"] || crumb["type"] || "No message"
        result += "- **[#{timestamp}]** #{category}: #{message}\n"
      end
      result += "\n"
    end

    # Runtime context
    contexts = event.contexts
    if contexts.present?
      result += "### Runtime Context\n\n"

      if contexts["runtime"]
        runtime = contexts["runtime"]
        result += "**Runtime:** #{runtime["name"]} #{runtime["version"]}\n" if runtime["name"]
      end

      if contexts["os"]
        os = contexts["os"]
        result += "**OS:** #{os["name"]} #{os["version"]}\n" if os["name"]
      end

      if contexts["device"]
        device = contexts["device"]
        result += "**Device:** #{device["model"]}\n" if device["model"]
      end
    end

    result
  end

  def format_transaction_stats(percentiles, top_endpoints, total_count, window, endpoint = nil)
    result = "## Transaction Performance Statistics\n\n"
    result += "**Endpoint:** #{endpoint}\n" if endpoint.present?
    result += "**Time Range:** #{window}\n"
    result += "**Total Transactions:** #{total_count}\n\n"

    if percentiles.empty?
      result += "No transaction data available.\n"
      return result
    end

    # percentiles is never `empty?` — it always carries the full key set — but
    # p50/p95/p99 come back nil for a window with no transactions, so these
    # have to go through format_ms rather than bare .round.
    result += "### Response Time Percentiles\n\n"
    result += "- **Average:** #{format_ms(percentiles[:avg])}\n"
    result += "- **Median (P50):** #{format_ms(percentiles[:p50])}\n"
    result += "- **P95:** #{format_ms(percentiles[:p95])}\n"
    result += "- **P99:** #{format_ms(percentiles[:p99])}\n\n"

    if top_endpoints.any?
      result += "### Top Endpoints by Impact (avg × count)\n\n"
      result += "| Endpoint | Time Spent | Avg | P95 | Count |\n"
      result += "|---|---:|---:|---:|---:|\n"
      top_endpoints.each do |row|
        result += "| #{row["transaction_name"]} " \
                 "| #{format_ms(row["time_spent"])} " \
                 "| #{format_ms(row["avg_duration"])} " \
                 "| #{format_ms(row["p95_duration"])} " \
                 "| #{row["count"]} |\n"
      end
    end

    result
  end

  def format_slow_transactions(transactions, min_duration_ms, max_duration_ms, window)
    band = max_duration_ms ? "#{min_duration_ms}–#{max_duration_ms}ms" : "≥#{min_duration_ms}ms"
    if transactions.empty?
      return "No slow transactions found (#{band}) in #{window}."
    end

    result = "## Slow Transactions (#{band})\n\n"
    result += "Found #{transactions.size} transaction(s):\n\n"

    transactions.each do |txn|
      result += "**Transaction ##{txn["id"]}** - #{txn["transaction_name"]}\n"
      result += "  - Duration: #{txn["duration"].round}ms\n"
      result += "  - Timestamp: #{txn["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "  - HTTP: #{txn["http_method"]} #{txn["http_status"]}\n" if txn["http_method"] || txn["http_status"]
      result += "  - Environment: #{txn["environment"]}\n" if txn["environment"]
      result += "  - Project: #{txn["project_name"]}\n\n" if txn["project_name"]
    end

    result
  end

  def format_transaction_detail(txn, trace_id = nil)
    result = "## Transaction ##{txn.id}: #{txn.transaction_name}\n\n"
    result += "**Transaction UUID:** #{txn.transaction_id}\n"
    result += "**Duration:** #{txn.duration.round}ms\n"
    result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
    result += "**Project:** #{txn.project.name}\n"
    result += "**Environment:** #{txn.environment}\n" if txn.environment
    result += "**Release:** #{txn.release}\n" if txn.release
    result += "**Server:** #{txn.server_name}\n" if txn.server_name
    if trace_id.present?
      result += "**Trace:** #{trace_id}\n"
      result += "_Call `get_trace_logs` with this trace_id for the correlated log lines._\n"
      # The reverse of the event detail's transaction hint: any errors thrown
      # during this request, so the correlation is discoverable from either end.
      errors = txn.related_events.limit(10).to_a
      if errors.any?
        result += "\n### Errors in this request (#{errors.size})\n"
        errors.each do |event|
          label = event.exception_type.presence || "Error"
          label += " — #{event.exception_value}" if event.exception_value.present?
          result += "- #{label} (event ##{event.id}; call `get_event` with id #{event.id})\n"
        end
      end
    end

    if txn.db_time || txn.view_time
      result += "\n### Time Breakdown\n"
      result += "- Database: #{txn.db_time.round}ms (#{txn.db_overhead_percentage}%)\n" if txn.db_time
      result += "- View: #{txn.view_time.round}ms (#{txn.view_overhead_percentage}%)\n" if txn.view_time
      if txn.duration.to_i > 0
        other_pct = (txn.other_time.to_f / txn.duration * 100).round(2)
        result += "- Other (middleware/queue): #{txn.other_time.round}ms (#{other_pct}%)\n"
      end
    end

    if txn.http_method || txn.http_status || txn.http_url
      result += "\n### HTTP Request\n"
      result += "- Method: #{txn.http_method}\n" if txn.http_method
      result += "- Status: #{txn.http_status}\n" if txn.http_status
      result += "- URL: #{txn.http_url}\n" if txn.http_url

      query_params = parse_query_params(txn.http_url)
      if query_params.any?
        result += "- Query Params:\n"
        query_params.each { |k, v| result += "  - #{k}: #{v}\n" }
      end
    end

    if txn.query_count > 0
      result += "\n### Query Analysis\n"
      result += "- Total queries: #{txn.query_count}\n"
      result += "- Unique patterns: #{txn.unique_query_patterns}\n"
      if txn.has_n_plus_one_queries?
        result += "- ⚠️ Potential N+1 patterns (#{txn.potential_n_plus_one_queries.size}):\n"
        txn.potential_n_plus_one_queries.first(5).each do |pattern|
          count = txn.query_patterns.dig(pattern, "count")
          distinct = txn.query_patterns.dig(pattern, "distinct_count")
          time_ms = txn.query_patterns.dig(pattern, "total_time_ms")
          # distinct == 1 means the byte-identical query fired N times
          # (memoisation/query-cache miss), not an N+1 over N records.
          note = if count && distinct == 1
            " (×#{count}, identical — memoisation, not eager loading)"
          elsif count && distinct
            " (×#{count}, #{distinct} distinct)"
          elsif count
            " (×#{count})"
          end
          note = "#{note} — #{format_ms(time_ms)} total" if note && time_ms
          result += "  - `#{pattern}`#{note}\n"
        end
      end
    end

    if txn.tags.is_a?(Hash) && txn.tags.any?
      result += "\n### Tags\n"
      txn.tags.each { |k, v| result += "- **#{k}:** #{v}\n" }
    end

    result
  end

  def format_transaction_spans(txn, all_spans, filtered_spans, op_filter, limit)
    result = "## Spans for Transaction ##{txn.id}: #{txn.transaction_name}\n\n"
    result += "**Transaction UUID:** #{txn.transaction_id}\n"
    result += "**Duration:** #{txn.duration.round}ms\n"
    result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
    result += "**Total Spans:** #{all_spans.size}"
    result += " (truncated at ingest — cap is #{Transaction::SPAN_CAP} per transaction)" if txn.spans_truncated
    result += "\n"
    result += "**Op Filter:** `#{op_filter}*`\n" if op_filter.present?
    result += "\n"

    if all_spans.empty?
      result += "No spans recorded for this transaction. Either the SDK didn't capture child spans, or the transaction is older than the span retention window.\n"
      return result
    end

    # Op summary across ALL spans (not filtered) — gives a holistic view
    by_op = all_spans.group_by { |s| s["op"].to_s }
    result += "### Op Summary\n\n"
    result += "| Op | Count | Total Time | Avg |\n"
    result += "|---|---:|---:|---:|\n"
    by_op.sort_by { |_, ss| -ss.sum { |s| s["duration_ms"].to_f } }.each do |op, ss|
      total = ss.sum { |s| s["duration_ms"].to_f }
      avg = total / ss.size
      op_label = op.presence || "(none)"
      result += "| `#{op_label}` | #{ss.size} | #{format_ms(total)} | #{format_ms(avg)} |\n"
    end
    result += "\n"

    # Repeated descriptions within the filtered set — N+1 fingerprint
    repeated = filtered_spans
      .select { |s| s["description"].to_s.strip.present? }
      .group_by { |s| s["description"].to_s }
      .select { |_, ss| ss.size > 3 }
      .sort_by { |_, ss| -ss.size }

    if repeated.any?
      result += "### Repeated Descriptions (potential N+1)\n\n"
      result += "Descriptions executed >3 times in this request:\n\n"
      repeated.first(15).each do |desc, ss|
        total = ss.sum { |s| s["duration_ms"].to_f }
        op = ss.first["op"]
        truncated = (desc.size > 400) ? "#{desc[0, 400]}…" : desc
        result += "- **×#{ss.size}** (#{format_ms(total)} total) `#{op}`\n"
        result += "  ```sql\n  #{truncated}\n  ```\n"
      end
      result += "\n"
    end

    # Span list
    shown = filtered_spans.first(limit)
    list_label = if op_filter.present?
      "Span List (filtered by op `#{op_filter}*`: #{shown.size} of #{filtered_spans.size}; #{all_spans.size} total)"
    else
      "Span List (#{shown.size} of #{all_spans.size})"
    end
    result += "### #{list_label}\n\n"

    shown.each do |s|
      depth = s["depth"].to_i
      indent = "  " * depth
      op = s["op"].to_s.presence || "(none)"
      desc = s["description"].to_s
      dur = s["duration_ms"].to_f
      line = "#{indent}- [#{format_ms(dur)}] `#{op}`"
      if desc.present?
        desc_truncated = (desc.size > 250) ? "#{desc[0, 250]}…" : desc
        line += " — #{desc_truncated}"
      end
      result += "#{line}\n"
    end

    if filtered_spans.size > limit
      result += "\n_#{filtered_spans.size - limit} more spans not shown — increase `limit` or narrow `op_filter`._\n"
    end

    result
  end

  def parse_query_params(url)
    return {} if url.blank? || !url.include?("?")
    query = url.split("?", 2).last
    URI.decode_www_form(query).to_h
  rescue ArgumentError
    {}
  end

  def format_endpoint_summary(endpoint, total_count, window, environment, release,
    percentiles, db_percentiles, view_percentiles,
    slowest_request, fastest_request)
    result = "## Endpoint Summary: #{endpoint}\n\n"
    result += "**Total Requests:** #{total_count}\n"
    result += "**Time Range:** #{window}\n"
    result += "**Environment:** #{environment}\n" if environment.present?
    result += "**Release:** #{release}\n" if release.present?
    result += "\n"

    # Overall performance
    result += "### Response Time Performance\n\n"
    result += "- **Average:** #{percentiles[:avg]&.round}ms\n"
    result += "- **Median (P50):** #{percentiles[:p50]&.round}ms\n"
    result += "- **P95:** #{percentiles[:p95]&.round}ms\n"
    result += "- **P99:** #{percentiles[:p99]&.round}ms\n"
    result += "- **Min:** #{percentiles[:min]&.round}ms\n"
    result += "- **Max:** #{percentiles[:max]&.round}ms\n\n"

    # Database performance
    if db_percentiles&.any?
      result += "### Database Performance\n\n"
      result += "- **Avg DB Time:** #{db_percentiles[:avg]&.round}ms\n"
      result += "- **P95 DB Time:** #{db_percentiles[:p95]&.round}ms\n\n"
    end

    # View performance
    if view_percentiles&.any?
      result += "### View Rendering Performance\n\n"
      result += "- **Avg View Time:** #{view_percentiles[:avg]&.round}ms\n"
      result += "- **P95 View Time:** #{view_percentiles[:p95]&.round}ms\n\n"
    end

    # Extreme examples
    result += "### Sample Requests\n\n"
    if fastest_request
      result += "**Fastest Request:** #{fastest_request["duration"].round}ms"
      result += " (DB: #{fastest_request["db_time"].round}ms)" if fastest_request["db_time"]
      result += " (View: #{fastest_request["view_time"].round}ms)" if fastest_request["view_time"]
      result += " - #{fastest_request["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
    end

    if slowest_request
      result += "**Slowest Request:** #{slowest_request["duration"].round}ms"
      result += " (DB: #{slowest_request["db_time"].round}ms)" if slowest_request["db_time"]
      result += " (View: #{slowest_request["view_time"].round}ms)" if slowest_request["view_time"]
      result += " - #{slowest_request["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
    end

    result
  end

  def format_n_plus_one_endpoints(rows, window, environment)
    header = "## Endpoints with N+1 Query Issues\n\n"
    header += "**Time Range:** #{window}\n"
    header += "**Environment:** #{environment}\n" if environment.present?
    header += "\n"

    if rows.empty?
      return header + "No N+1 patterns detected in this window.\n"
    end

    header += "| Endpoint | N+1 / Total | % Affected | Avg Queries | Max Queries | Wasted | Wasted/req | Avg | P95 |\n"
    header += "|---|---:|---:|---:|---:|---:|---:|---:|---:|\n"
    rows.each do |r|
      wasted = r["n_plus_one_time"].to_i
      header += "| #{r["transaction_name"]} " \
               "| #{r["n_plus_one_count"]} / #{r["total_count"]} " \
               "| #{r["n_plus_one_pct"]}% " \
               "| #{r["avg_queries"].to_f.round(1)} " \
               "| #{r["max_queries"]} " \
               "| #{wasted.positive? ? format_ms(wasted) : "—"} " \
               "| #{wasted.positive? ? format_ms(r["avg_n_plus_one_time"]) : "—"} " \
               "| #{format_ms(r["avg_duration"])} " \
               "| #{format_ms(r["p95_duration"])} |\n"
    end
    header += "\nWasted = db time spent inside the repeated patterns across the window. " \
      "— means no span timing was recorded for the flagged patterns (rows from before wasted-time tracking, or spans not sampled).\n"
    header
  end

  def format_endpoint_timeseries(endpoint, series, window, buckets, bucket_seconds, requested_buckets,
    environment, release, start_time)
    bucket_minutes = (bucket_seconds / 60.0).round

    header = "## Endpoint Time Series: #{endpoint}\n\n"
    header += "**Time Range:** #{window}\n"
    header += "**Buckets:** #{buckets} × #{bucket_minutes}m\n"
    if buckets != requested_buckets
      header += "_Requested #{requested_buckets} buckets; widened to #{bucket_minutes}m so each bucket is a whole number of hours and the series can be served from the hourly rollups._\n"
    end
    header += "**Environment:** #{environment}\n" if environment.present?
    header += "**Release:** #{release}\n" if release.present?
    header += "\n"

    # time_series_for_endpoint returns string-keyed buckets: an integer
    # "bucket" index plus "count" and "p50"/"p95"/"p99" (no avg/max). Derive
    # each bucket's wall-clock start from its index and the window origin.
    if series.all? { |b| b["count"].zero? }
      return header + "No requests in this window.\n"
    end

    header += "| Bucket Start | Count | P50 | P95 | P99 |\n"
    header += "|---|---:|---:|---:|---:|\n"
    series.each do |b|
      bucket_start = start_time + (b["bucket"] * bucket_seconds)
      header += "| #{bucket_start.strftime("%Y-%m-%d %H:%M")} " \
               "| #{b["count"]} " \
               "| #{format_ms(b["p50"])} " \
               "| #{format_ms(b["p95"])} " \
               "| #{format_ms(b["p99"])} |\n"
    end
    header
  end

  def format_ms(value)
    return "—" if value.nil?
    "#{value.to_f.round}ms"
  end

  def format_transactions_by_endpoint(transactions, endpoint, window, environment, release)
    if transactions.empty?
      result = "No transactions found for endpoint '#{endpoint}'"
      result += " with the specified filters." if environment.present? || release.present?
      return result
    end

    result = "## Recent Transactions: #{endpoint}\n\n"
    result += "**Showing:** #{transactions.size} transaction(s)\n"
    result += "**Time Range:** #{window}\n"
    result += "**Environment:** #{environment}\n" if environment.present?
    result += "**Release:** #{release}\n" if release.present?
    result += "\n"

    transactions.each_with_index do |txn, index|
      result += "### Transaction #{index + 1}\n"
      result += "**ID:** ##{txn.id}\n"
      result += "**Duration:** #{txn.duration.round}ms"
      result += " (DB: #{txn.db_time.round}ms)" if txn.db_time
      result += " (View: #{txn.view_time.round}ms)" if txn.view_time
      result += "\n"
      result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "**HTTP:** #{txn.http_method} #{txn.http_status}\n" if txn.http_method || txn.http_status
      result += "**Environment:** #{txn.environment}\n" if txn.environment
      result += "**Release:** #{txn.release}\n" if txn.release
      result += "**Server:** #{txn.server_name}\n" if txn.server_name
      result += "**Project:** #{txn.project.name}\n"
      result += "\n"
    end

    result
  end

  def format_performance_comparison(endpoint, comparison_type, before_label, after_label,
    before_transactions, after_transactions)
    result = "## Performance Comparison: #{endpoint}\n\n"
    result += "**Comparison Type:** #{comparison_type}\n"
    result += "**Before Period:** #{before_label}\n"
    result += "**After Period:** #{after_label}\n\n"

    # before_transactions / after_transactions are already sorted Arrays of
    # durations (see durations_for in the controller).
    before_durations = before_transactions
    after_durations = after_transactions
    before_count = before_durations.size
    after_count = after_durations.size

    before_stats = calculate_percentiles(before_durations)
    after_stats = calculate_percentiles(after_durations)

    if before_stats.empty? && after_stats.empty?
      return "No transaction data available for comparison."
    end

    # Summary table
    result += "### Performance Summary\n\n"
    result += "| Metric | Before | After | Change |\n"
    result += "|--------|--------|-------|--------|\n"
    result += "| **Requests** | #{before_count} | #{after_count} | #{format_count_change(before_count, after_count)} |\n"

    if before_stats[:avg] && after_stats[:avg]
      avg_change = format_percentage_change(before_stats[:avg], after_stats[:avg])
      result += "| **Avg Duration** | #{before_stats[:avg].round}ms | #{after_stats[:avg].round}ms | #{avg_change} |\n"
    end

    if before_stats[:p50] && after_stats[:p50]
      p50_change = format_percentage_change(before_stats[:p50], after_stats[:p50])
      result += "| **Median (P50)** | #{before_stats[:p50].round}ms | #{after_stats[:p50].round}ms | #{p50_change} |\n"
    end

    if before_stats[:p95] && after_stats[:p95]
      p95_change = format_percentage_change(before_stats[:p95], after_stats[:p95])
      result += "| **P95** | #{before_stats[:p95].round}ms | #{after_stats[:p95].round}ms | #{p95_change} |\n"
    end

    if before_stats[:p99] && after_stats[:p99]
      p99_change = format_percentage_change(before_stats[:p99], after_stats[:p99])
      result += "| **P99** | #{before_stats[:p99].round}ms | #{after_stats[:p99].round}ms | #{p99_change} |\n"
    end

    # Analysis
    result += "\n### Analysis\n\n"
    if before_stats[:avg] && after_stats[:avg]
      if after_stats[:avg] < before_stats[:avg]
        improvement = ((before_stats[:avg] - after_stats[:avg]) / before_stats[:avg] * 100).round(1)
        result += "✅ **Performance improved by #{improvement}%** (average duration decreased)\n\n"
      else
        degradation = ((after_stats[:avg] - before_stats[:avg]) / before_stats[:avg] * 100).round(1)
        result += "⚠️ **Performance degraded by #{degradation}%** (average duration increased)\n\n"
      end
    end

    # before_transactions/after_transactions are sorted ascending arrays of
    # raw durations (see durations_for) — last element is the slowest.
    if before_transactions.any?
      result += "**Slowest request (before):** #{before_transactions.last.round}ms\n"
    end

    if after_transactions.any?
      result += "**Slowest request (after):** #{after_transactions.last.round}ms\n"
    end

    result
  end

  def format_percentage_change(before, after)
    return "N/A" if before.nil? || after.nil? || before == 0

    change = ((after - before) / before * 100).round(1)
    if change > 0
      "+#{change}%"
    else
      "#{change}%"
    end
  end

  def format_count_change(before, after)
    if after == before
      "No change"
    elsif after > before
      "+#{after - before} (#{((after - before).to_f / before * 100).round(1)}%)"
    else
      "#{after - before} (#{((after - before).to_f / before * 100).round(1)}%)"
    end
  end
end
