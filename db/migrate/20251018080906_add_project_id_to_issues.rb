class AddProjectIdToIssues < ActiveRecord::Migration[8.1]
  def change
    add_reference :issues, :project, null: false, foreign_key: true
  end
end
