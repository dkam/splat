class RenameTransactionToTransactionNameInEvents < ActiveRecord::Migration[8.1]
  def change
    rename_column :events, :transaction, :transaction_name
  end
end
