class AddProjectTraceIdIndexToLogs < ActiveRecord::Migration[8.1]
  # TransactionsController#show renders a "View N logs for this trace" link,
  # backed by `SELECT COUNT(*) FROM logs WHERE project_id = ? AND trace_id = ?`.
  # The only trace_id index was single-column, so SQLite planned this against a
  # project_id-prefixed index and walked a huge slice of the high-volume logs
  # table row-by-row — ~198s on the meta instance, dominating the whole request.
  # A composite [project_id, trace_id] index turns the count into a covering
  # index-only range scan. Mirrors index_transactions_on_project_id_and_trace_id.
  def change
    add_index :logs, [:project_id, :trace_id], name: "index_logs_on_project_id_and_trace_id"
  end
end
