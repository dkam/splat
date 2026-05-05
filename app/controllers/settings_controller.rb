class SettingsController < ApplicationController
  before_action :set_setting, only: [:update]

  def index
    @setting = Setting.instance
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
      :ducklake_issues_retention_days
    )
  end
end
