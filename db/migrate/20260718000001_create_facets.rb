# frozen_string_literal: true

class CreateFacets < ActiveRecord::Migration[8.1]
  def change
    create_table :facets do |t|
      t.integer :project_id, null: false
      t.string :stream, null: false
      t.string :name, null: false
      t.string :value, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    add_index :facets, [:project_id, :stream, :name, :value], unique: true, name: "index_facets_on_scope_and_value"
    add_index :facets, [:project_id, :stream, :name], name: "index_facets_on_scope"
    add_foreign_key :facets, :projects
  end
end
