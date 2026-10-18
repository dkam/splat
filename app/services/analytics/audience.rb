# frozen_string_literal: true

module Analytics
  # Who a set of events came from — one client hammering a page, or everyone?
  # Counts each event's IP, network, user, browser and system
  # (SentryProtocol::Client). None of those are columns, so it decompresses
  # the payloads, and only of the newest `sample` events: enough to tell one
  # from many without a busy window costing a payload per event.
  class Audience
    SAMPLE = 500

    # How many of a dimension's values to name; the rest are counted, not
    # listed.
    TOP = 4

    Dimension = Data.define(:key, :label, :top, :distinct, :missing)

    DIMENSIONS = {
      ip: "IP",
      network: "network",
      user: "user",
      browser: "browser",
      os: "system"
    }.freeze

    def initialize(events, sample: SAMPLE)
      @events = events
      @sample = sample
    end

    def dimensions
      @dimensions ||= begin
        counts = DIMENSIONS.keys.index_with { Hash.new(0) }
        rows = @events.reorder(timestamp: :desc, id: :desc).limit(@sample).select(:id, :payload_blob, :dict_id)
        @read = 0
        rows.each do |event|
          @read += 1
          values(event.payload || {}).each { |key, value| counts[key][value] += 1 if value }
        end
        DIMENSIONS.map do |key, label|
          tally = counts[key]
          Dimension.new(key:, label:, top: tally.sort_by { |value, n| [-n, value] }.first(TOP),
            distinct: tally.size, missing: @read - tally.values.sum)
        end
      end
    end

    def read
      dimensions
      @read
    end

    private

    def values(payload)
      ip = SentryProtocol::Client.ip(payload)
      user_agent = SentryProtocol::Client.user_agent(payload)
      {
        ip: ip,
        network: SentryProtocol::Client.network(ip),
        user: SentryProtocol::Client.user(payload),
        browser: SentryProtocol::Client.browser(user_agent),
        os: SentryProtocol::Client.os(user_agent)
      }
    end
  end
end
