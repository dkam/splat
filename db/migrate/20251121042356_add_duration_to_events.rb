class AddDurationToEvents < ActiveRecord::Migration[8.1]
  def change
    # Add duration field for consistency with Transaction model
    add_column :events, :duration, :integer, default: 0, null: false

    # Convert fingerprint from JSON to string for DuckDB compatibility
    # This ensures compatibility with DuckDB which expects VARCHAR
    change_column :events, :fingerprint, :string, limit: 1000

    # Add index for analytical queries
    add_index :events, :duration
  end
end
