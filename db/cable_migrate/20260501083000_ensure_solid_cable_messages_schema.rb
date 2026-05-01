# frozen_string_literal: true

# Restores the solid_cable_messages table that was lost when
# db/cable_schema.rb was overwritten during the Rails 8.1 upgrade
# (commit 2828ce1), and adds an explicit unique index on id to work
# around https://github.com/rails/rails/issues/41848 — Rails 8.1's
# InsertAll#find_unique_index_for can fail to recognise SQLite's
# implicit primary key, raising "No unique index found for id" on
# every Turbo broadcast.
class EnsureSolidCableMessagesSchema < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:solid_cable_messages)
      create_table :solid_cable_messages do |t|
        t.binary :channel, limit: 1024, null: false
        t.binary :payload, limit: 536_870_912, null: false
        t.datetime :created_at, null: false
        t.integer :channel_hash, limit: 8, null: false
        t.index :channel, name: "index_solid_cable_messages_on_channel"
        t.index :channel_hash, name: "index_solid_cable_messages_on_channel_hash"
        t.index :created_at, name: "index_solid_cable_messages_on_created_at"
      end
    end

    unless index_exists?(:solid_cable_messages, :id, name: "index_solid_cable_messages_on_id")
      add_index :solid_cable_messages, :id, unique: true, name: "index_solid_cable_messages_on_id"
    end
  end

  def down
    if index_exists?(:solid_cable_messages, :id, name: "index_solid_cable_messages_on_id")
      remove_index :solid_cable_messages, name: "index_solid_cable_messages_on_id"
    end
  end
end
