# frozen_string_literal: true

module Logs
  # Ensures the logs_fts FTS5 search index (virtual table + sync triggers)
  # exists on the logs DB. Idempotent. Called at boot (config/initializers/
  # logs_fts.rb) and per worker in parallel tests — virtual tables and triggers
  # can't be represented in the :ruby schema, so neither db:schema:load nor the
  # parallel-test DB setup creates them.
  module Fts
    module_function

    def ensure!
      return unless LogsRecord.connection_pool.db_config.adapter.to_s.include?("sqlite3")

      conn = LogsRecord.connection

      conn.execute(<<~SQL)
        CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
          body, attrs_text, content='logs', content_rowid='id'
        )
      SQL

      conn.execute(<<~SQL)
        CREATE TRIGGER IF NOT EXISTS logs_fts_ai AFTER INSERT ON logs BEGIN
          INSERT INTO logs_fts(rowid, body, attrs_text) VALUES (new.id, new.body, new.attrs_text);
        END
      SQL
      conn.execute(<<~SQL)
        CREATE TRIGGER IF NOT EXISTS logs_fts_ad AFTER DELETE ON logs BEGIN
          INSERT INTO logs_fts(logs_fts, rowid, body, attrs_text) VALUES ('delete', old.id, old.body, old.attrs_text);
        END
      SQL
      conn.execute(<<~SQL)
        CREATE TRIGGER IF NOT EXISTS logs_fts_au AFTER UPDATE ON logs BEGIN
          INSERT INTO logs_fts(logs_fts, rowid, body, attrs_text) VALUES ('delete', old.id, old.body, old.attrs_text);
          INSERT INTO logs_fts(rowid, body, attrs_text) VALUES (new.id, new.body, new.attrs_text);
        END
      SQL

      # First boot after the table is created (or a fresh schema:load): index
      # rows already present. 'rebuild' re-reads the whole content table; only
      # runs while the index is empty.
      #
      # Emptiness is read from logs_fts_docsize (one row per indexed document),
      # NOT from logs_fts itself. logs_fts is external-content, so querying it
      # reads the *content* table — `SELECT count(*) FROM logs_fts` returns the
      # logs count and `SELECT rowid ... LIMIT 1` returns a logs id, both
      # completely unchanged by an empty index. Verified: after
      # `INSERT INTO logs_fts(logs_fts) VALUES('delete-all')`, search returns
      # nothing while count(*) still reports every log. Reading logs_fts to ask
      # about the index is measuring the wrong table.
      #
      # It's also the difference between a boot and a hang. This runs at boot in
      # every process (web, workers, console, runner); count(*) scans all of
      # logs — 18.3 GB / 14.5M rows in production, ~5-7s warm and far worse
      # cold. The docsize probe is a single row from a plain shadow table.
      if conn.select_value("SELECT 1 FROM logs_fts_docsize LIMIT 1").nil? &&
          !conn.select_value("SELECT rowid FROM logs LIMIT 1").nil?
        conn.execute("INSERT INTO logs_fts(logs_fts) VALUES('rebuild')")
        Rails.logger.info("[logs_fts] rebuilt index from existing logs rows")
      end
    end
  end
end
