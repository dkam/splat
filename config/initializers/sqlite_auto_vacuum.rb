# frozen_string_literal: true

# Ensure the two high-churn data DBs use auto_vacuum=INCREMENTAL so
# Maintenance::RetentionJob's `PRAGMA incremental_vacuum` can actually return
# freed pages to the OS after retention deletes rows. Without it those files
# only ever grow.
#
# Why here and not database.yml or the migration:
#   * A connect-time `pragmas: { auto_vacuum: ... }` is silently ineffective:
#     the foreign_keys/journal_mode pragmas read the schema first, after which
#     SQLite ignores an auto_vacuum change until a VACUUM. (Verified empirically.)
#   * db/*_migrate/..._enable_incremental_vacuum.rb fixes the migrate path, but a
#     fresh deploy runs `db:schema:load` and marks that migration applied WITHOUT
#     running it — so fresh DBs would stay auto_vacuum=NONE.
#
# Setting the pragma + VACUUM at boot backfills both cases. It's a cheap pragma
# check (and skip) once the mode is already INCREMENTAL; the converting VACUUM
# only runs when the mode is wrong, and is effectively instant on the empty DB a
# fresh deploy produces.
Rails.application.config.after_initialize do
  [:issues_events, :transactions_spans].each do |db_key|
    base =
      case db_key
      when :issues_events      then IssuesEventsRecord
      when :transactions_spans then TransactionsSpansRecord
      end

    begin
      next unless base.connection_pool.db_config.adapter.to_s.include?("sqlite3")

      conn = base.connection
      next if conn.select_value("PRAGMA auto_vacuum").to_i == 2 # 2 = INCREMENTAL

      conn.execute("PRAGMA auto_vacuum = INCREMENTAL")
      conn.execute("VACUUM")
      Rails.logger.info("[sqlite_auto_vacuum] set auto_vacuum=INCREMENTAL on #{base.name}")
    rescue => e
      # DB may not exist yet (db:create), be mid-migration, or be unreachable
      # during asset precompile. Safe to skip — the next boot retries.
      Rails.logger.warn("[sqlite_auto_vacuum] skipped #{base.name}: #{e.class}: #{e.message}")
    end
  end
end
