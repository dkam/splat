class AddTraceIdToTransactions < ActiveRecord::Migration[8.1]
  def change
    # trace_id used to live only on spans. Promote it to the transaction so
    # log↔transaction correlation no longer needs a cross-transaction span query
    # (LogsController#related_transaction) once spans become a per-transaction blob.
    add_column :transactions, :trace_id, :string
    add_index :transactions, [:project_id, :trace_id]
  end
end
