# frozen_string_literal: true

module ParquetLake
  # Helpers for walking the Hive-partitioned Parquet tree and extracting
  # Date objects from `year=YYYY/month=M/day=D` directory paths. Used by
  # CompactionJob and RetentionJob.
  module PartitionPath
    module_function

    # Returns Date for a path containing year=/month=/day= segments, or nil
    # if the segments are missing or yield an invalid date (e.g. month=13).
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

    # Globs all day-partition directories for a table.
    def partition_dirs(data_path, table)
      Dir.glob(File.join(data_path, table.to_s, "year=*", "month=*", "day=*"))
    end
  end
end
