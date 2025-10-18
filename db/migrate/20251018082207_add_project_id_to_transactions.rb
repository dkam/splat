class AddProjectIdToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :transactions, :project, null: false, foreign_key: true
  end
end
