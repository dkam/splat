class CreateSpans < ActiveRecord::Migration[8.1]
  def change
    create_table :spans do |t|
      t.integer :project_id, null: false
      t.string :transaction_id, null: false
      t.string :trace_id
      t.string :span_id, null: false
      t.string :parent_span_id
      t.datetime :timestamp, null: false
      t.datetime :end_timestamp
      t.string :op
      t.string :status
      t.text :description
      t.integer :depth, default: 0, null: false
      t.integer :sequence, default: 0, null: false

      # Compressed { tags: ..., data: ... } JSON.
      t.binary :payload_blob
      t.bigint :dict_id

      t.datetime :created_at, null: false
    end

    add_index :spans, [:project_id, :transaction_id, :sequence]
    add_index :spans, :timestamp
    add_index :spans, [:project_id, :op, :timestamp]
  end
end
