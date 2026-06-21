class SettingsController < ApplicationController
  before_action :set_setting, only: [:update]

  def index
    @setting = Setting.instance

    # Read the precomputed snapshot — never run the dbstat scan inline (it
    # walks every page of each DB file and can take tens of seconds). On a
    # cold cache (fresh deploy) the snapshot is nil; show a pending state and
    # enqueue a build so the next view has it. The 15m scheduled job keeps it
    # fresh thereafter.
    @storage = StorageStats.snapshot
    StorageStats.enqueue_refresh if @storage.nil?
  end

  def update
    if @setting.update(setting_params)
      redirect_to settings_path, notice: "Settings updated successfully."
    else
      redirect_to settings_path, alert: "Error updating settings: #{@setting.errors.full_messages.join(", ")}"
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
