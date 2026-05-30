class SettingsController < ApplicationController
  before_action :set_setting, only: [:update]

  def index
    @setting = Setting.instance
    @postgres_tables = StorageStats.postgres_tables
    @ducklake_tables = StorageStats.ducklake_tables
    @postgres_total = @postgres_tables.sum { |t| t[:total_bytes] }
    @ducklake_total = @ducklake_tables.sum { |t| t[:total_bytes] }
    @ducklake_delete_total = @ducklake_tables.sum { |t| t[:delete_bytes] }
  end

  def update
    if @setting.update(setting_params)
      redirect_to settings_path, notice: "Settings updated successfully."
    else
      redirect_to settings_path, alert: "Error updating settings: #{@setting.errors.full_messages.join(', ')}"
    end
  end

  private

  def set_setting
    @setting = Setting.instance
  end

  def setting_params
    params.require(:setting).permit(
      :event_payloads_retention_days,
      :events_data_retention_days,
      :transaction_measurements_retention_days,
      :transactions_data_retention_days,
      :ducklake_events_retention_days,
      :ducklake_transactions_retention_days,
      :ducklake_issues_retention_days,
      :ducklake_spans_retention_days
    )
  end
end
