class CreateSpanTrees < ActiveRecord::Migration[8.1]
  def change
    create_table :span_trees do |t|
      t.integer :project_id, null: false
      t.string :transaction_id, null: false
      # Retention key — set to the owning transaction's timestamp so span_trees
      # age out on the same clock the legacy spans did.
      t.datetime :timestamp, null: false

      # One zstd-compressed JSON blob holding the whole span tree. dict_id is
      # nullable and unused for now (plain zstd); reserved for a future
      # hand-trained spans dictionary, seeded like events/logs.
      t.binary :payload_blob, null: false
      t.bigint :dict_id

      t.integer :span_count, null: false, default: 0
      t.boolean :spans_truncated, null: false, default: false

      t.datetime :created_at, null: false
    end

    # Unique on (project_id, transaction_id): the dual-read lookup seek and the
    # ingest idempotency guard (transaction_id is not globally unique across projects).
    add_index :span_trees, [:project_id, :transaction_id], unique: true
    add_index :span_trees, :timestamp
  end
end
