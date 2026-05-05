# frozen_string_literal: true

class AddReleaseTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :first_seen_release, :string
    add_column :issues, :last_seen_release, :string

    create_table :releases do |t|
      t.references :project, null: false, foreign_key: true, index: true
      t.string :version, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :event_count, default: 0, null: false
      t.integer :transaction_count, default: 0, null: false
      t.timestamps
    end

    add_index :releases, [:project_id, :version], unique: true
    add_index :releases, [:project_id, :first_seen_at]
  end
end
