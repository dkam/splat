class NtfyNotificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(issue_id, event_type)
    issue = Issue.find_by(id: issue_id)
    return unless issue

    case event_type.to_s
    when "new_issue"
      NtfyNotifier.notify_new_issue(issue)
    when "issue_reopened"
      NtfyNotifier.notify_issue_reopened(issue)
    when "issue_burst"
      NtfyNotifier.notify_issue_burst(issue)
    else
      Rails.logger.warn("NtfyNotificationJob: unknown event_type=#{event_type.inspect}")
    end
  end
end
