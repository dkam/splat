# frozen_string_literal: true

# Ensure each data DB is set to a self-reclaiming auto_vacuum mode so freed
# pages are returned to the OS instead of leaving the file to only ever grow.
#
#   * :issues_events / :transactions_spans are high-churn (retention deletes
#     rows daily). They use INCREMENTAL so Maintenance::RetentionJob's
#     `PRAGMA incremental_vacuum` can hand the freed pages back in bounded,
#     off-peak batches.
#   * :primary is near-zero churn (oidc_sessions/settings only). It has no
#     vacuum caller, so it uses FULL — pages return automatically on every
#     commit. The per-commit cost is negligible at primary's write rate, and
#     it self-maintains without depending on a checkpoint winning a lock race.
#     (Backstory: a one-time pre-rewrite migration left ~15GB of free pages in
#     primary that nothing ever reclaimed; FULL prevents a recurrence.)
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
# check (and skip) once the mode is already correct; the converting VACUUM only
# runs when the mode is wrong, and is effectively instant on the small DBs a
# fresh deploy (or a freshly-vacuumed primary) produces.
Rails.application.config.after_initialize do
  # db base class => [target mode pragma value, mode name for the pragma + log]
  # 1 = FULL, 2 = INCREMENTAL
  targets = {
    ApplicationRecord => [1, "FULL"],
    IssuesEventsRecord => [2, "INCREMENTAL"],
    TransactionsSpansRecord => [2, "INCREMENTAL"],
    LogsRecord => [2, "INCREMENTAL"]
  }

  targets.each do |base, (mode_value, mode_name)|
    next unless base.connection_pool.db_config.adapter.to_s.include?("sqlite3")

    conn = base.connection
    next if conn.select_value("PRAGMA auto_vacuum").to_i == mode_value

    conn.execute("PRAGMA auto_vacuum = #{mode_name}")
    conn.execute("VACUUM")
    Rails.logger.info("[sqlite_auto_vacuum] set auto_vacuum=#{mode_name} on #{base.name}")
  rescue => e
    # DB may not exist yet (db:create), be mid-migration, or be unreachable
    # during asset precompile. Safe to skip — the next boot retries.
    Rails.logger.warn("[sqlite_auto_vacuum] skipped #{base.name}: #{e.class}: #{e.message}")
  end
end
