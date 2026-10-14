class WebhookNotificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(issue_id, event_type)
    issue = Issue.find_by(id: issue_id)
    return unless issue

    case event_type.to_s
    when "new_issue" then WebhookNotifier.notify_new_issue(issue)
    when "issue_reopened" then WebhookNotifier.notify_issue_reopened(issue)
    when "issue_burst" then WebhookNotifier.notify_issue_burst(issue)
    else Rails.logger.warn("WebhookNotificationJob: unknown event_type=#{event_type.inspect}")
    end
  end
end
