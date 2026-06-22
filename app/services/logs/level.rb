# frozen_string_literal: true

module Logs
  # Maps source-specific severity onto the Log#level enum
  # (trace/debug/info/warn/error/fatal).
  module Level
    # Some SDKs/loggers spell these differently than our enum.
    ALIASES = {
      "warning" => "warn",
      "err" => "error",
      "critical" => "fatal",
      "crit" => "fatal",
      "panic" => "fatal"
    }.freeze

    module_function

    # Sentry sends a level string. Returns the enum integer, or nil if unknown.
    def from_string(str)
      return nil if str.nil? || str.to_s.strip.empty?
      key = str.to_s.downcase
      key = ALIASES[key] || key
      Log.levels[key]
    end

    # OTLP severity_number is a 1–24 scale bucketed in groups of four
    # (TRACE/DEBUG/INFO/WARN/ERROR/FATAL). Returns the enum integer, or nil.
    def from_otlp_number(num)
      return nil if num.nil?
      case num.to_i
      when 1..4 then Log.levels["trace"]
      when 5..8 then Log.levels["debug"]
      when 9..12 then Log.levels["info"]
      when 13..16 then Log.levels["warn"]
      when 17..20 then Log.levels["error"]
      when 21..24 then Log.levels["fatal"]
      end
    end
  end
end
