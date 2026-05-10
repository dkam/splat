module ApplicationHelper
  include Pagy::Frontend

  # Maps each section of the project-level tab strip to the controllers
  # that belong to it. Used by `_project_nav` to highlight the active tab.
  PROJECT_NAV_SECTIONS = {
    overview:    %w[projects],
    errors:      %w[issues events],
    performance: %w[endpoints transactions]
  }.freeze

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
    gap = bar_count > 32 ? 0.5 : 1
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
    when /\Adb\./           then "bg-blue-500"
    when /\Ahttp\./         then "bg-orange-500"
    when /\A(?:view|template|render)\./ then "bg-green-500"
    when /\Acache\./        then "bg-purple-500"
    when /\Aqueue\./        then "bg-pink-500"
    else "bg-gray-500"
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
