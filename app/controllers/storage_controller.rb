class StorageController < ApplicationController
  def show
    @postgres_tables = StorageStats.postgres_tables
    @ducklake_tables = StorageStats.ducklake_tables
    @postgres_total = @postgres_tables.sum { |t| t[:total_bytes] }
    @ducklake_total = @ducklake_tables.sum { |t| t[:total_bytes] }
    @ducklake_delete_total = @ducklake_tables.sum { |t| t[:delete_bytes] }
  end
end
