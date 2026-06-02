# frozen_string_literal: true

module ParquetLake
  # Daily retention: rm -rf any day-partition older than retention_days
  # (from config/parquet_lake.yml). After deleting day dirs, empty parent
  # year/month dirs are removed too so the tree stays tidy.
  class RetentionJob
    TABLES = %w[events transactions spans].freeze
    DEFAULT_RETENTION_DAYS = 30

    def perform(retention_days: nil)
      retention_days ||= (Rails.application.config.x.parquet_lake[:retention_days] || DEFAULT_RETENTION_DAYS).to_i
      cutoff = Date.current - retention_days

      data_path = ParquetLake::Connection.data_path
      removed = 0
      TABLES.each do |table|
        # day_dirs (not partition_dirs) so we delete the whole day at once —
        # works for both the legacy day-level layout and the new layout where
        # the day dir contains 24 hour=H subdirs.
        PartitionPath.day_dirs(data_path, table).each do |dir|
          date = PartitionPath.date_from(dir)
          next unless date && date < cutoff
          FileUtils.rm_rf(dir)
          removed += 1
        end
        cleanup_empty_parents(File.join(data_path, table))
      end
      Rails.logger.info "[ParquetLake] retention: removed #{removed} day-partition(s) older than #{cutoff}"
      removed
    end

    private

    # Remove `month=*` dirs that no longer contain any `day=*` children,
    # then `year=*` dirs that no longer contain any `month=*` children.
    def cleanup_empty_parents(table_root)
      return unless File.directory?(table_root)

      Dir.glob(File.join(table_root, "year=*", "month=*")).each do |month_dir|
        Dir.rmdir(month_dir) if Dir.empty?(month_dir)
      end
      Dir.glob(File.join(table_root, "year=*")).each do |year_dir|
        Dir.rmdir(year_dir) if Dir.empty?(year_dir)
      end
    end
  end
end
