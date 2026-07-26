class AddProjectTraceTimestampIndexToLogs < ActiveRecord::Migration[8.1]
  # LogsController#index with ?trace_id= runs
  # `... WHERE project_id = ? AND trace_id = ? ORDER BY timestamp DESC LIMIT 51`.
  # The [project_id, trace_id] index added in 20260711000001 fixed the *count*
  # query, but the list query's ORDER BY reopens the same hole: given a choice
  # between an index that filters and one that supplies the sort order for free,
  # SQLite takes the sort. It planned this against
  # index_logs_on_project_id_and_timestamp binding project_id only, then walked
  # the project's entire history row-by-row testing trace_id — 26M rows on the
  # Booko instance, which hung the page outright (and, with Puma at 3 threads,
  # the whole site behind it).
  #
  # Appending timestamp lets one index serve both the equality filter and the
  # ordering: `SEARCH logs USING INDEX ... (project_id=? AND trace_id=?)` with no
  # temp b-tree. The 3-column index is a strict superset of the 2-column one —
  # the 20260711000001 count stays a covering index-only scan on the prefix — so
  # the old index is dropped rather than left to duplicate it.
  #
  # Both steps are guarded by name, because on a large instance this index is
  # better built out-of-band with the sqlite3 CLI than by db:prepare at boot:
  #
  #   1. CREATE INDEX is a write transaction, so in WAL mode readers keep
  #      serving off their snapshot — the site stays up. Running it via
  #      bin/docker-entrypoint's db:prepare instead blocks web startup for the
  #      whole build.
  #   2. The Rails connection sets temp_store: memory (config/database.yml), so
  #      sorting ~26M index entries happens in RAM. The CLI defaults to spilling
  #      to disk.
  #
  # Pre-build it (with the splat.logs and splat.maintenance writers stopped),
  # using exactly these names, and this migration lands as a no-op:
  #
  #   CREATE INDEX index_logs_on_project_id_and_trace_id_and_timestamp
  #     ON logs (project_id, trace_id, timestamp);
  #   DROP INDEX index_logs_on_project_id_and_trace_id;
  NEW_INDEX = "index_logs_on_project_id_and_trace_id_and_timestamp"
  OLD_INDEX = "index_logs_on_project_id_and_trace_id"

  def up
    unless index_name_exists?(:logs, NEW_INDEX)
      add_index :logs, [:project_id, :trace_id, :timestamp], name: NEW_INDEX
    end

    if index_name_exists?(:logs, OLD_INDEX)
      remove_index :logs, [:project_id, :trace_id], name: OLD_INDEX
    end
  end

  def down
    unless index_name_exists?(:logs, OLD_INDEX)
      add_index :logs, [:project_id, :trace_id], name: OLD_INDEX
    end

    if index_name_exists?(:logs, NEW_INDEX)
      remove_index :logs, [:project_id, :trace_id, :timestamp], name: NEW_INDEX
    end
  end
end
