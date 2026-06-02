# frozen_string_literal: true

module ParquetLake
  # Helpers for walking the Hive-partitioned Parquet tree. Two layouts coexist
  # during the migration window:
  #   - new: <table>/year=Y/month=M/day=D/hour=H/<uuid>.parquet
  #   - legacy: <table>/year=Y/month=M/day=D/<uuid>.parquet  (pre-2026-06-02)
  # Reads via `read_parquet('<table>/**/*.parquet')` match both. Compaction
  # operates only on the new layout (hour-level partitions). Retention works
  # at day granularity so it cleans up both layouts uniformly.
  module PartitionPath
    module_function

    # Returns Date from any path containing year=/month=/day= segments (ignores
    # any hour= segment). Used for both compaction's cutoff check and retention.
    def date_from(path)
      parts = path.split(File::SEPARATOR)
      year  = parts.find { |p| p.start_with?("year=") }&.delete_prefix("year=")&.to_i
      month = parts.find { |p| p.start_with?("month=") }&.delete_prefix("month=")&.to_i
      day   = parts.find { |p| p.start_with?("day=") }&.delete_prefix("day=")&.to_i
      return nil unless year && month && day && year.positive? && month.positive? && day.positive?
      Date.new(year, month, day)
    rescue ArgumentError
      nil
    end

    # Hour-partition directories (new layout). Used by compaction — each
    # directory's files merge into one ordered file per hour. One hour's
    # data is bounded enough to fit in DuckDB's memory limit.
    def partition_dirs(data_path, table)
      Dir.glob(File.join(data_path, table.to_s, "year=*", "month=*", "day=*", "hour=*"))
    end

    # Day-partition directories. Used by retention — rm -rf on a day dir
    # removes both legacy day-level files and the new hour subdirs in one
    # shot, so we don't need separate retention paths per layout.
    def day_dirs(data_path, table)
      Dir.glob(File.join(data_path, table.to_s, "year=*", "month=*", "day=*"))
    end
  end
end
