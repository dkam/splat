class CreateLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :logs do |t|
      t.integer :project_id, null: false
      # UUIDv7 generated at ingest. Logs carry no stable upstream id, so this
      # is a local identifier for the show page / MCP lookups. No unique index:
      # logs are high-volume and a rare beanstalkd redelivery dup is acceptable.
      t.string :log_id
      t.datetime :timestamp, null: false

      # Severity. `level` is the normalized enum (trace..fatal); severity_number
      # preserves the raw OTLP 1–24 scale when the source is OTLP.
      t.integer :level
      t.integer :severity_number

      t.text :body
      t.string :logger_name

      # Trace correlation — the key cross-link to a transaction/spans.
      t.string :trace_id
      t.string :span_id

      t.string :environment
      t.string :release
      t.string :server_name

      # "sentry" | "otlp" — origin, and the dictionary segmentation key
      # (shapes differ enough per source that per-source dicts compress better).
      t.string :source

      # Compressed full record (zstd, dictionary-segmented). dict_id NULL means
      # plain zstd (no dictionary), otherwise references compression_dictionaries.id.
      t.binary :payload_blob
      t.bigint :dict_id

      t.timestamps
    end

    add_index :logs, [:project_id, :timestamp]
    add_index :logs, :timestamp
    add_index :logs, :trace_id
    add_index :logs, :level
    add_index :logs, :environment
    add_index :logs, :log_id
  end
end
