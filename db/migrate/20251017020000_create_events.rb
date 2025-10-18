class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.references :project, null: false, foreign_key: true
      t.string :event_id, null: false
      t.datetime :timestamp, null: false
      t.string :platform
      t.string :sdk_name
      t.string :sdk_version

      # Error details
      t.string :exception_type
      t.text :exception_value
      t.text :message

      # Context
      t.string :environment
      t.string :release
      t.string :server_name
      t.string :transaction

      # Grouping
      t.json :fingerprint
      t.bigint :issue_id

      # Full payload for details view
      t.json :payload

      t.timestamps
    end

    # Essential indexes only
    add_index :events, [:project_id, :event_id], unique: true
    add_index :events, :timestamp
    add_index :events, :issue_id
    add_index :events, :environment
  end
end

    add_index :events, :event_id, unique: true
    add_index :events, :timestamp
    add_index :events, :exception_type
    add_index :events, :issue_id
    add_index :events, :environment
    add_index :events, :platform
    add_index :events, :transaction
    add_index :events, [ :project_id, :event_id ], unique: true
  end
end
