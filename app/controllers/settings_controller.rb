class SettingsController < ApplicationController
  before_action :set_setting, only: [:update]

  def index
    @setting = Setting.instance
    @sqlite_groups = StorageStats.sqlite_tables_grouped
    @sqlite_total  = @sqlite_groups.sum { |g| g[:tables].sum { |t| t[:total_bytes] } }
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
      :events_data_retention_days,
      :transactions_data_retention_days,
      :spans_data_retention_days,
      :histograms_retention_days,
      :burst_threshold,
      :ntfy_url,
      :ntfy_token,
      :ntfy_priority
    )
  end
end
