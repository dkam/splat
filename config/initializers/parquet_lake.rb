# frozen_string_literal: true

# Loads config/parquet_lake.yml (with ERB) for the current Rails env and
# stashes the parsed hash on Rails.application.config.x.parquet_lake. The
# DuckDB connection used by ParquetLake::Connection is opened lazily on
# first use, so this initializer does no I/O beyond reading the yml.

require "yaml"
require "erb"

config_path = Rails.root.join("config", "parquet_lake.yml")
unless config_path.exist?
  Rails.logger&.warn("[ParquetLake] config/parquet_lake.yml not found; analytics layer unconfigured")
  return
end

raw = ERB.new(config_path.read, trim_mode: "-").result
parsed = YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol]) || {}
env_config = parsed[Rails.env] || parsed["default"] || {}

Rails.application.config.x.parquet_lake = env_config.deep_symbolize_keys
