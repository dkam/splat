class AddLevelAndEnvironmentTimestampIndexesToLogs < ActiveRecord::Migration[8.1]
  # `search_logs` with no full-text query at all still wedged the tool surface —
  # the other half of the 2026-09-12 Booko report, and the same shape as the FTS
  # bug fixed in 1.18.0 wearing a different index.
  #
  # Measured on production (109 GB logs DB, 14.4M rows): a `level: :error`
  # search over a 30-minute window asking for 3 rows took 34.5s, and queued two
  # ingest POSTs behind it for the whole 34.5s. The plan:
  #
  #   SEARCH logs USING INDEX index_logs_on_level (level=?)
  #   USE TEMP B-TREE FOR ORDER BY
  #
  # With a bare single-column index on a low-cardinality column, SQLite costs
  # `level = ?` as the selective term — it isn't; `error` spans the full 14-day
  # retention window — walks every match, fetches each row to test the
  # timestamp, then sorts the lot before LIMIT can apply. The window contributes
  # nothing and there is no early exit. `environment` is worse: 'production' is
  # very nearly every row.
  #
  # Carrying the ordering column in the same index lets the range and the sort
  # share one traversal. The bare indexes are then strict prefixes of the new
  # ones — they can serve nothing the composite can't, and leaving them in place
  # just leaves the planner a worse option to pick, so they go.
  #
  # Only a concern when `project` is absent: with a project_id the planner
  # already chooses index_logs_on_project_id_and_timestamp. That is why the
  # narrow project+level retry in the incident report returned in under a
  # second while the unscoped one timed out.
  #
  # Guarded by name, as with 20260726000001/2, so a large instance can build
  # these out-of-band with the sqlite3 CLI before deploying (CREATE INDEX is a
  # write txn — WAL readers keep serving, but db:prepare at boot would block
  # web startup for as long as the sort takes on 14.4M rows):
  #
  #   CREATE INDEX index_logs_on_level_and_timestamp       ON logs (level, timestamp);
  #   CREATE INDEX index_logs_on_environment_and_timestamp ON logs (environment, timestamp);
  #   DROP INDEX   index_logs_on_level;
  #   DROP INDEX   index_logs_on_environment;
  NEW_INDEXES = {
    "index_logs_on_level_and_timestamp" => [:level, :timestamp],
    "index_logs_on_environment_and_timestamp" => [:environment, :timestamp]
  }.freeze

  SUPERSEDED = {
    "index_logs_on_level" => [:level],
    "index_logs_on_environment" => [:environment]
  }.freeze

  def up
    NEW_INDEXES.each do |name, columns|
      add_index :logs, columns, name: name unless index_name_exists?(:logs, name)
    end

    # Only after the replacements exist, so there is never a window with no
    # index on these columns at all.
    SUPERSEDED.each_key do |name|
      remove_index :logs, name: name if index_name_exists?(:logs, name)
    end
  end

  def down
    SUPERSEDED.each do |name, columns|
      add_index :logs, columns, name: name unless index_name_exists?(:logs, name)
    end

    NEW_INDEXES.each_key do |name|
      remove_index :logs, name: name if index_name_exists?(:logs, name)
    end
  end
end
