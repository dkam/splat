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
    #   read_parquet('<data_path>/<table>/**/*.parquet', hive_partitioning=true) AS <table>
    # The AS alias keeps the rest of each query readable; column refs in the
    # SQL bodies are unqualified, so the alias is just for EXPLAIN clarity.
    def from_clause
      raise Error, "table_name not set on #{name}" unless table_name
      "read_parquet('#{ParquetLake::Connection.glob_for(table_name)}', hive_partitioning=true) AS #{table_name}"
    end
  end
end
