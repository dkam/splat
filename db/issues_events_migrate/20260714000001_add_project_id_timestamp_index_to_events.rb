class AddProjectIdTimestampIndexToEvents < ActiveRecord::Migration[8.1]
  def change
    # Windowed per-project reads (dashboard event counts, volume/issue
    # sparklines) filter on project_id + timestamp. Without a composite index
    # SQLite falls back to scanning wide event rows (compressed payloads), which
    # took seconds on the project dashboard; with it these are index-only.
    add_index :events, [:project_id, :timestamp]
  end
end
