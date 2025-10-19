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
