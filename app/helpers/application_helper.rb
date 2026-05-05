module ApplicationHelper
  include Pagy::Frontend

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
  def sparkline(values, width: 96, height: 24, color: "currentColor", title: nil)
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

    title_attr = title ? %(<title>#{ERB::Util.html_escape(title)}</title>) : ""

    tag.svg(
      (title_attr + bars).html_safe,
      viewBox: "0 0 #{width} #{height}",
      width: width,
      height: height,
      role: "img",
      "aria-label": title || "sparkline",
      class: "inline-block align-middle",
      preserveAspectRatio: "none"
    )
  end

  # Return CSS class based on duration performance
  def duration_color_class(ms)
    return "text-gray-400" if ms.nil?

    ms = ms.to_f
    if ms >= 2000 # 2+ seconds - very slow
      "text-red-600"
    elsif ms >= 1000 # 1-2 seconds - slow
      "text-orange-600"
    elsif ms >= 500 # 500ms-1s - moderate
      "text-yellow-600"
    else # < 500ms - fast
      "text-green-600"
    end
  end
end
