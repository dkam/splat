class AddWebhookToSettings < ActiveRecord::Migration[8.1]
  # Issue alerts POSTed to a URL — see WebhookNotifier. The format is the body:
  # Splat's own JSON, or a Slack or Discord message. The secret signs the JSON.
  def change
    add_column :settings, :webhook_url, :string
    add_column :settings, :webhook_format, :string, default: "json", null: false
    add_column :settings, :webhook_secret, :string
  end
end
