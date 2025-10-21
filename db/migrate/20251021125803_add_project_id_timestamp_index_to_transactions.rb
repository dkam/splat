class AddProjectIdTimestampIndexToTransactions < ActiveRecord::Migration[8.1]
  def change
    # Add composite index for project-scoped timestamp queries
    # This optimizes queries like: WHERE project_id = X AND timestamp BETWEEN Y AND Z
    add_index :transactions, [:project_id, :timestamp], name: 'index_transactions_on_project_id_and_timestamp'
  end
end
