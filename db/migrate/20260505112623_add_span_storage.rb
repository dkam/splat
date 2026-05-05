# frozen_string_literal: true

class AddSpanStorage < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :spans_truncated, :boolean, default: false, null: false
    add_column :settings, :ducklake_spans_retention_days, :integer, default: 30, null: false
  end
end
