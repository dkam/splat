# frozen_string_literal: true

# Loads config/ducklake.yml (with ERB) for the current Rails env and stashes
# the parsed hash on Rails config. The actual DuckDB connection is opened
# lazily by ApplicationDucklakeRecord on first use.

require "yaml"
require "erb"

config_path = Rails.root.join("config", "ducklake.yml")
unless config_path.exist?
  Rails.logger&.warn("[DuckLake] config/ducklake.yml not found; analytics layer disabled")
  return
end

raw = ERB.new(config_path.read, trim_mode: "-").result
parsed = YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol]) || {}
env_config = parsed[Rails.env] || parsed["default"] || {}

Rails.application.config.x.ducklake = env_config.deep_symbolize_keys

if Rails.application.config.eager_load
  Rails.application.config.after_initialize do
    begin
      ApplicationDucklakeRecord.bootstrap!
    rescue => e
      Rails.logger.error("[DuckLake] bootstrap failed: #{e.class}: #{e.message}")
    end
  end
end
