class CreateCompressionDictionaries < ActiveRecord::Migration[8.1]
  def change
    create_table :compression_dictionaries do |t|
      t.string :segment, null: false
      t.integer :version, null: false
      t.binary :dict, null: false
      t.datetime :trained_at, null: false
      t.integer :sample_count
      t.float :baseline_ratio
      t.boolean :active, default: false, null: false

      t.timestamps
    end

    add_index :compression_dictionaries, [:segment, :version], unique: true
    add_index :compression_dictionaries, :segment, unique: true, where: "active = 1", name: "index_compression_dictionaries_on_active_segment"
  end
end
