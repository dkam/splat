class AddTraceIdIndexToSpans < ActiveRecord::Migration[8.1]
  def change
    # LogsController#related_transaction resolves a log's trace_id to its
    # owning transaction with
    # `SELECT transaction_id FROM spans WHERE project_id = ? AND trace_id = ? LIMIT 1`.
    # The spans table had no index covering trace_id (only project_id+op+timestamp,
    # project_id+transaction_id+sequence, and timestamp), so every log-detail
    # page view triggered a full table scan of the highest-volume table —
    # making /projects/:slug/logs/:id slow. A composite on (project_id, trace_id)
    # turns that into an index lookup.
    add_index :spans, [:project_id, :trace_id]
  end
end
