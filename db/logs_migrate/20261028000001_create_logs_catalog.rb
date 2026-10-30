# The logs database became the catalog in ADR 0005: logs moved to one file per
# day (Logs::DayFiles), and what stays here is what every day file shares, the
# compression dictionaries and their training runs. It's a new file, so this
# starts it from nothing; the migrations that built the old logs database went
# with it. Logs::Catalog.import_legacy! copies that database's dictionaries in.
class CreateLogsCatalog < ActiveRecord::Migration[8.1]
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

    create_table :dictionary_training_runs do |t|
      t.string :segment, null: false
      t.datetime :ran_at, null: false
      t.integer :samples
      t.float :current_ratio
      t.float :candidate_ratio
      t.float :gain
      t.boolean :promoted, default: false, null: false
      t.integer :promoted_to_version
      t.text :notes
    end

    add_index :dictionary_training_runs, [:segment, :ran_at]
  end
end
