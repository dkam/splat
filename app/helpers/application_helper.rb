module ApplicationHelper
  include Pagy::Frontend

  # Maps each section of the project-level tab strip to the controllers
  # that belong to it. Used by `_project_nav` to highlight the active tab.
  PROJECT_NAV_SECTIONS = {
    overview: %w[projects],
    errors: %w[issues events],
    performance: %w[endpoints transactions],
    logs: %w[logs]
  }.freeze

  # Tailwind classes for a log level badge.
  LOG_LEVEL_BADGE_CLASSES = {
    "trace" => "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400",
    "debug" => "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300",
    "info" => "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300",
    "warn" => "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    "error" => "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
    "fatal" => "bg-red-200 text-red-900 dark:bg-red-900/60 dark:text-red-200"
  }.freeze

  def log_level_badge_class(level)
    LOG_LEVEL_BADGE_CLASSES.fetch(level.to_s, LOG_LEVEL_BADGE_CLASSES["debug"])
  end

  def project_nav_active?(section)
    return false unless @project
    controllers = PROJECT_NAV_SECTIONS.fetch(section, [])
    return false if controllers.empty?
    # Overview only matches when on projects#show, not projects#index
    if section == :overview
      controllers.include?(controller_name) && action_name == "show"
    else
      controllers.include?(controller_name)
    end
  end

  # Format duration in milliseconds to human-readable string
  def format_duration(ms)
    return "N/A" if ms.nil?

    ms = ms.to_f
    if ms >= 1000
      "#{(ms / 1000.0).round(2)}s"
    else
      "#{ms.round}ms"
    end
  end

  # Render a tiny inline-SVG bar sparkline. Each value becomes one bar; bars
  # scale to the max value in the series so a single chart's shape is what
  # tells you the story (not the absolute height).
  def sparkline(values, width: 96, height: 24, color: "currentColor", title: nil,
    markers: nil, time_range: nil)
    values = Array(values)
    return "".html_safe if values.empty?

    max = values.max.to_f
    bar_count = values.size
    gap = (bar_count > 32) ? 0.5 : 1
    bar_width = [(width.to_f - gap * (bar_count - 1)) / bar_count, 0.5].max

    bars = values.each_with_index.map do |v, i|
      next if v.to_i.zero?
      x = (i * (bar_width + gap)).round(2)
      bar_height = max.zero? ? 0 : (v.to_f / max * (height - 1)).round(2)
      bar_height = 1 if bar_height < 1
      y = (height - bar_height).round(2)
      %(<rect x="#{x}" y="#{y}" width="#{bar_width.round(2)}" height="#{bar_height}" fill="#{color}" rx="0.5" />)
    end.compact.join

    marker_lines = ""
    if markers.present? && time_range
      span = (time_range.end - time_range.begin).to_f
      if span > 0
        marker_lines = Array(markers).map do |m|
          frac = ((m - time_range.begin).to_f / span).clamp(0, 1)
          x = (frac * width).round(2)
          %(<line x1="#{x}" x2="#{x}" y1="0" y2="#{height}" stroke="#9ca3af" stroke-width="1" stroke-dasharray="2,1" opacity="0.6" />)
        end.join
      end
    end

    title_attr = title ? %(<title>#{ERB::Util.html_escape(title)}</title>) : ""

    tag.svg(
      (title_attr + marker_lines + bars).html_safe,
      viewBox: "0 0 #{width} #{height}",
      width: width,
      height: height,
      role: "img",
      "aria-label": title || "sparkline",
      class: "inline-block align-middle",
      preserveAspectRatio: "none"
    )
  end

  # Tailwind colour for a span's bar in the waterfall view, keyed off the
  # Sentry op prefix. Op taxonomy is ~30 distinct values; bucketing by prefix
  # gets us 90% of the legibility for none of the per-op upkeep.
  def span_op_color(op)
    return "bg-gray-400" if op.blank?
    case op
    when /\Adb\./ then "bg-blue-500"
    when /\Ahttp\./ then "bg-orange-500"
    when /\A(?:view|template|render)\./ then "bg-green-500"
    when /\Acache\./ then "bg-purple-500"
    when /\Aqueue\./ then "bg-pink-500"
    else "bg-gray-500"
    end
  end

  # Compact label for a release string. Booko's releases look like
  # "2026-06-22T13:00:00+10:00-<40-char git sha>" — far too wide for a table
  # cell. When the value matches that shape we show "Jun 22 13:00 · 80541a9";
  # otherwise we fall back to a plain truncation. The full release is always
  # kept in the element's title attribute (see the view), so nothing is lost.
  def format_release(release)
    return nil if release.blank?

    timestamp, _, sha = release.rpartition("-")
    if timestamp.present? && sha.match?(/\A[0-9a-f]{7,40}\z/i)
      begin
        return "#{Time.parse(timestamp).strftime("%b %-d %H:%M")} · #{sha[0, 7]}"
      rescue ArgumentError
        # not a parseable timestamp — drop through to the generic truncation
      end
    end

    truncate(release, length: 20)
  end

  # Shared Tailwind classes for a single pagination control (link or label).
  PAGY_ITEM_BASE = "inline-flex items-center justify-center min-w-[2.25rem] h-9 px-3 rounded-md text-sm font-medium border transition-colors"
  PAGY_ITEM_INACTIVE = "#{PAGY_ITEM_BASE} border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
  PAGY_ITEM_ACTIVE = "#{PAGY_ITEM_BASE} border-blue-600 bg-blue-600 text-white"
  PAGY_ITEM_DISABLED = "#{PAGY_ITEM_BASE} border-gray-200 dark:border-gray-800 text-gray-400 dark:text-gray-600 cursor-not-allowed"

  # Styled, page-numbered pagination for regular (counted) Pagy objects. Drop-in
  # replacement for `pagy_nav`, whose unstyled output renders as a row of jammed
  # numbers under Tailwind. Used by the endpoints and issues lists.
  def pagy_nav_tailwind(pagy)
    return "".html_safe if pagy.pages <= 1

    items = pagy.series.map do |item|
      case item
      when Integer
        link_to(item, pagy_url_for(pagy, item), class: PAGY_ITEM_INACTIVE)
      when String # the current page is yielded as a String
        tag.span(item, class: PAGY_ITEM_ACTIVE, "aria-current": "page")
      when :gap
        tag.span("…", class: "inline-flex items-center justify-center h-9 px-2 text-gray-400 dark:text-gray-600")
      end
    end

    tag.nav("aria-label": "Pagination", class: "flex flex-wrap items-center gap-1.5") do
      safe_join([pagy_prev_tag(pagy), *items, pagy_next_tag(pagy)])
    end
  end

  # Styled prev/next pagination for countless Pagy objects (the logs feed),
  # which have no total page count — just a current page and whether more exist.
  def pagy_nav_countless_tailwind(pagy)
    return "".html_safe if pagy.prev.nil? && pagy.next.nil?

    tag.nav("aria-label": "Pagination", class: "flex items-center justify-center gap-3") do
      safe_join([
        pagy_prev_tag(pagy),
        tag.span("Page #{pagy.page}", class: "text-sm text-gray-500 dark:text-gray-400 tabular-nums"),
        pagy_next_tag(pagy)
      ])
    end
  end

  # Prev/next controls shared by both nav helpers; render as a disabled label
  # when there's no page to go to.
  def pagy_prev_tag(pagy)
    if pagy.prev
      link_to("‹ Prev", pagy_url_for(pagy, pagy.prev), class: PAGY_ITEM_INACTIVE, rel: "prev", "aria-label": "Previous page")
    else
      tag.span("‹ Prev", class: PAGY_ITEM_DISABLED, "aria-disabled": "true")
    end
  end

  def pagy_next_tag(pagy)
    if pagy.next
      link_to("Next ›", pagy_url_for(pagy, pagy.next), class: PAGY_ITEM_INACTIVE, rel: "next", "aria-label": "Next page")
    else
      tag.span("Next ›", class: PAGY_ITEM_DISABLED, "aria-disabled": "true")
    end
  end

  # Return CSS class based on duration performance
  def duration_color_class(ms)
    return "text-gray-400 dark:text-gray-500" if ms.nil?

    ms = ms.to_f
    if ms >= 2000 # 2+ seconds - very slow
      "text-red-600 dark:text-red-400"
    elsif ms >= 1000 # 1-2 seconds - slow
      "text-orange-600 dark:text-orange-400"
    elsif ms >= 500 # 500ms-1s - moderate
      "text-yellow-600 dark:text-yellow-400"
    else # < 500ms - fast
      "text-green-600 dark:text-green-400"
    end
  end
end
