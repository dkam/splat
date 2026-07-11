# frozen_string_literal: true

# Full-text search over logs via SQLite FTS5.
#
# logs_fts is an external-content FTS5 table (it indexes `body` + `attrs_text`
# straight from `logs`, storing only the inverted index, not a copy of the
# rows). Three triggers keep it in sync — and crucially they fire on bulk
# INSERT/DELETE (Log.insert_all! at ingest, RetentionJob's delete_all), which AR
# callbacks would miss.
#
# Why here and not a migration: the FTS5 virtual table and its triggers can't be
# represented in the :ruby schema, so a fresh deploy's `db:schema:load` would
# silently ship without them and search would return nothing. Ensuring them at
# boot (idempotent) backfills both the migrate path and the schema:load path —
# the same approach config/initializers/sqlite_auto_vacuum.rb uses for the
# auto_vacuum pragma. See Logs::Fts.ensure! for the shared logic (also invoked
# per worker in parallel tests).
# Keep the FTS5 virtual table and its shadow tables (logs_fts, logs_fts_data,
# _idx, _docsize, _config) out of the :ruby schema dump. They can't be
# represented there — and worse, AR 8.1's SQLite dumper crashes on an
# external-content FTS5 table (its `arguments` come back nil → `nil.split`),
# truncating db/logs_schema.rb mid-write on every `db:migrate`. Logs::Fts.ensure!
# owns them at boot instead, so nothing is lost by omitting them here.
ActiveRecord::SchemaDumper.ignore_tables |= [/\Alogs_fts(_|\z)/]

Rails.application.config.after_initialize do
  Logs::Fts.ensure!
rescue => e
  # DB may not exist yet (db:create), be mid-migration, or lack the attrs_text
  # column on an older deploy. Safe to skip — the next boot retries.
  Rails.logger.warn("[logs_fts] skipped: #{e.class}: #{e.message}")
end
