class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.string :event_id, null: false
      t.integer :project_id, null: false
      t.bigint :issue_id
      t.datetime :timestamp, null: false
      t.integer :duration, default: 0, null: false
      t.string :environment
      t.string :exception_type
      t.text :exception_value
      t.string :fingerprint, limit: 1000
      t.text :message
      t.string :platform
      t.string :release
      t.string :sdk_name
      t.string :sdk_version
      t.string :server_name
      t.string :transaction_name

      # Compressed Sentry payload (zstd, dictionary-segmented). dict_id
      # NULL means plain zstd (no dictionary), otherwise references
      # compression_dictionaries.id.
      t.binary :payload_blob
      t.bigint :dict_id

      t.timestamps
    end

    add_index :events, [:project_id, :event_id], unique: true
    add_index :events, :project_id
    add_index :events, :issue_id
    add_index :events, :timestamp
    add_index :events, :environment
    add_index :events, :duration
  end
end
