# frozen_string_literal: true

# Base class for the Parquet-backed analytics models (events/transactions/spans).
# Subclasses set `self.table_name` and use the class-level API; there are no
# instances. Calls flow through ParquetLake::Connection, which holds a thread-
# local DuckDB connection that reads partitioned Parquet via read_parquet().
class ApplicationParquetLakeRecord
  class Error < StandardError; end

  class_attribute :table_name, instance_accessor: false

  class << self
    # Returns [{column_name => value}, ...] for the given SELECT.
    def query(sql, *binds)
      ParquetLake::Connection.query(sql, *binds)
    end

    # SQL fragment for the FROM clause of every analytics query:
    #   read_parquet('<data_path>/<table>/**/*.parquet') AS <table>
    #
    # `hive_partitioning=true` is intentionally omitted: during the day→hour
    # migration window, legacy files live at year=/month=/day=/ (3 levels)
    # while new files live at year=/month=/day=/hour=/ (4 levels). DuckDB's
    # hive_partitioning refuses to read files with inconsistent partition
    # depth ("Hive partition mismatch"). Without it, DuckDB just opens each
    # file's footer for min/max-based pruning — slightly slower per query
    # but transparent to read correctness. After retention sweeps the legacy
    # 3-level files (≤30 days), we can re-enable hive_partitioning for the
    # extra path-pruning win.
    def from_clause
      raise Error, "table_name not set on #{name}" unless table_name
      "read_parquet('#{ParquetLake::Connection.glob_for(table_name)}') AS #{table_name}"
    end
  end
end
