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
      if conn.select_value("SELECT count(*) FROM logs_fts").to_i.zero? &&
          conn.select_value("SELECT count(*) FROM logs").to_i.positive?
        conn.execute("INSERT INTO logs_fts(logs_fts) VALUES('rebuild')")
        Rails.logger.info("[logs_fts] rebuilt index from existing logs rows")
      end
    end
  end
end
