class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues do |t|
      t.references :project, null: false, foreign_key: true
      t.string :fingerprint, null: false
      t.string :title, null: false
      t.string :exception_type
      
      # Statistics
      t.integer :count, default: 0
      t.datetime :first_seen, null: false
      t.datetime :last_seen, null: false
      
      # Status
      t.string :status, default: 'unresolved', null: false
      
      t.timestamps
    end
    
    # Essential indexes only
    add_index :issues, [:project_id, :fingerprint], unique: true
    add_index :issues, :status
    add_index :issues, :last_seen
  end
end

    add_index :issues, :fingerprint, unique: true
    add_index :issues, :status
    add_index :issues, :last_seen
    add_index :issues, :count
  end
end
