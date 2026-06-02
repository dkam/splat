# frozen_string_literal: true

module ParquetLake
  # Daily compaction: for each (table, day-partition) older than today,
  # merge the per-batch Parquet files into a single file ordered by
  # timestamp. ORDER BY at write time crushes ZSTD/dictionary compression
  # on time-series data because adjacent rows share environment/release/
  # server_name/transaction_name values.
  #
  # Safe to run repeatedly: a partition with only one file is skipped.
  # Mid-run failures leave a `.tmp` file in the partition that the next
  # successful run cleans up.
  class CompactionJob
    TABLES = %w[events transactions spans].freeze

    # Today's partition is excluded — writers are still appending to it.
    # Yesterday and older are merged. Each partition is one hour's worth of
    # data, which fits in DuckDB's memory limit even on the events table.
    def perform(cutoff_date: Date.current)
      data_path = ParquetLake::Connection.data_path
      ParquetLake::Connection.execute("SET preserve_insertion_order = false")
      compacted = 0
      TABLES.each do |table|
        PartitionPath.partition_dirs(data_path, table).each do |dir|
          partition_date = PartitionPath.date_from(dir)
          next unless partition_date && partition_date < cutoff_date
          compacted += 1 if compact_partition(table, dir)
        end
      end
      Rails.logger.info "[ParquetLake] compaction: merged #{compacted} partition(s)"
      compacted
    end

    private

    def compact_partition(table, partition_dir)
      files = Dir.glob(File.join(partition_dir, "*.parquet"))
      return false if files.size < 2

      uuid = SecureRandom.uuid_v7
      tmp_path   = File.join(partition_dir, ".#{uuid}.parquet.tmp")
      final_path = File.join(partition_dir, "#{uuid}.parquet")

      file_list_sql = files.map { |f| "'#{escape(f)}'" }.join(", ")

      # EXCLUDE the hive partition columns: hive_partitioning=true injects
      # year/month/day/hour as virtual columns derived from the directory
      # path. We don't want them in the merged file's row data — the
      # directory path still provides the partition information on read.
      ParquetLake::Connection.execute(<<~SQL)
        COPY (
          SELECT * EXCLUDE (year, month, day, hour)
          FROM read_parquet([#{file_list_sql}], hive_partitioning=true)
          ORDER BY timestamp
        ) TO '#{escape(tmp_path)}' (FORMAT PARQUET, COMPRESSION ZSTD)
      SQL

      File.rename(tmp_path, final_path)
      files.each { |f| File.unlink(f) rescue nil }
      Rails.logger.info "[ParquetLake] compacted #{table}/#{File.basename(partition_dir)}: #{files.size} files → 1"
      true
    rescue => e
      Rails.logger.error "[ParquetLake] compaction failed for #{table}/#{partition_dir}: #{e.class}: #{e.message}"
      File.unlink(tmp_path) if tmp_path && File.exist?(tmp_path) && !File.exist?(final_path)
      false
    end

    def escape(s)
      s.to_s.gsub("'", "''")
    end
  end
end
