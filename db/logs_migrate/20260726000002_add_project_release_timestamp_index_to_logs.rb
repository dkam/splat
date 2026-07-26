class AddProjectReleaseTimestampIndexToLogs < ActiveRecord::Migration[8.1]
  # Release is now a log filter (LogsController#index and the search_logs MCP
  # tool), which means
  # `... WHERE project_id = ? AND release = ? ORDER BY timestamp DESC LIMIT 51`
  # — the same shape that hung the trace_id filter in 20260726000001. Without an
  # index carrying both the equality and the ordering, SQLite plans against
  # index_logs_on_project_id_and_timestamp for the free sort and then walks the
  # project's whole history testing release. A release filter is *especially*
  # exposed to this: it selects a slice of one deploy out of the full retention
  # window, so the rows it wants are a thin band and everything before them gets
  # scanned first.
  #
  # Ship the index with the feature rather than after someone hits it.
  #
  # As with 20260726000001, this is guarded by name so a large instance can
  # build it out-of-band with the sqlite3 CLI (CREATE INDEX is a write txn, so
  # WAL readers keep serving; db:prepare at boot would block web startup):
  #
  #   CREATE INDEX index_logs_on_project_id_and_release_and_timestamp
  #     ON logs (project_id, release, timestamp);
  NEW_INDEX = "index_logs_on_project_id_and_release_and_timestamp"

  def up
    return if index_name_exists?(:logs, NEW_INDEX)

    add_index :logs, [:project_id, :release, :timestamp], name: NEW_INDEX
  end

  def down
    return unless index_name_exists?(:logs, NEW_INDEX)

    remove_index :logs, [:project_id, :release, :timestamp], name: NEW_INDEX
  end
end
