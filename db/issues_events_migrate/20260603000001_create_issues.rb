class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues do |t|
      t.integer :project_id, null: false
      t.string :fingerprint, null: false
      t.string :title, null: false
      t.string :exception_type
      t.integer :count, default: 0
      t.datetime :first_seen, null: false
      t.datetime :last_seen, null: false
      t.string :first_seen_release
      t.string :last_seen_release
      t.integer :status, default: 0, null: false

      t.timestamps
    end

    add_index :issues, [:project_id, :fingerprint], unique: true
    add_index :issues, :project_id
    add_index :issues, :last_seen
    add_index :issues, :status
  end
end
