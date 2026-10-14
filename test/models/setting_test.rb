# frozen_string_literal: true

require "test_helper"

class SettingTest < ActiveSupport::TestCase
  def setting
    @setting ||= Setting.instance
  end

  test "a webhook is off without a URL, and on with one" do
    setting.webhook_url = ""
    assert setting.valid?
    refute setting.webhook_configured?

    setting.webhook_url = "https://hooks.example/splat"
    assert setting.webhook_configured?
  end

  test "rejects a webhook URL that isn't http(s)" do
    setting.webhook_url = "ftp://hooks.example/splat"
    refute setting.valid?
    assert setting.errors[:webhook_url].present?
  end

  test "rejects a webhook format it can't send" do
    setting.webhook_format = "teams"
    refute setting.valid?
    assert setting.errors[:webhook_format].present?
  end

  test "valid with a blank ntfy_url (ntfy disabled)" do
    setting.ntfy_url = ""
    assert setting.valid?
    refute setting.ntfy_configured?
  end

  test "ntfy_configured? is true once a url is set" do
    setting.ntfy_url = "https://ntfy.sh/my-topic"
    assert setting.ntfy_configured?
  end

  test "rejects an unparseable ntfy_url" do
    setting.ntfy_url = "not a url"
    refute setting.valid?
    assert setting.errors[:ntfy_url].present?
  end

  test "rejects an out-of-range ntfy_priority" do
    setting.ntfy_priority = "screaming"
    refute setting.valid?
    assert setting.errors[:ntfy_priority].present?
  end

  test "accepts a valid ntfy_priority" do
    setting.assign_attributes(ntfy_url: "https://ntfy.sh/t", ntfy_priority: "high")
    assert setting.valid?
  end

  test "burst_threshold must be positive" do
    setting.burst_threshold = 0
    refute setting.valid?
    assert setting.errors[:burst_threshold].present?
  end
end
