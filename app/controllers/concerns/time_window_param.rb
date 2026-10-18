# frozen_string_literal: true

# ?from=&to= as a time range, for the lists the project timeline opens: a click
# on a bucket lists its events or its logs. ISO 8601 or epoch seconds. nil when
# either is missing or unreadable, or the range runs backwards, so the caller
# falls back to its usual view rather than an empty one.
module TimeWindowParam
  extend ActiveSupport::Concern

  private

  def time_window_param
    from = parse_window_time(params[:from])
    to = parse_window_time(params[:to])
    (from...to) if from && to && from < to
  end

  def parse_window_time(value)
    value = value.to_s.strip
    return nil if value.empty?
    return Time.at(Integer(value, 10)).utc if value.match?(/\A\d+\z/)

    Time.iso8601(value).utc
  rescue ArgumentError
    nil
  end
end
