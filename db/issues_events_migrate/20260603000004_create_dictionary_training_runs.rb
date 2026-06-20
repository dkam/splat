class CreateDictionaryTrainingRuns < ActiveRecord::Migration[8.1]
  def change
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
