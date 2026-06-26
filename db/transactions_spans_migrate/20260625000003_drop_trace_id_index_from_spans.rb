class DropTraceIdIndexFromSpans < ActiveRecord::Migration[8.1]
  # Run ONLY after splat:backfill_transaction_trace_id has populated
  # transactions.trace_id — until then LogsController#related_transaction still
  # relies on this index. Once trace_id lives on transactions, the per-span
  # trace_id index (~1.2 GB in prod) is dead weight.
  def up
    remove_index :spans, name: "index_spans_on_project_id_and_trace_id"
  end

  def down
    add_index :spans, [:project_id, :trace_id], name: "index_spans_on_project_id_and_trace_id"
  end
end
