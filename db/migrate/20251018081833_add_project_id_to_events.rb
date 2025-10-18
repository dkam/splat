class AddProjectIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :events, :project, null: false, foreign_key: true
  end
end
