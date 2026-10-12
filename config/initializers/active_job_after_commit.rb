# frozen_string_literal: true

# Put a job on tuber only once the transaction that queued it has committed.
#
# Issue's after_create alerts (IssueMailer.new_issue, NtfyNotificationJob) run
# inside the INSERT's transaction, and the worker reserved the mail job within
# milliseconds, before the commit. Under 1.21.0's single worker container every
# new-issue email failed with "Couldn't find Issue" (907-910 on 2026-10-12),
# and ntfy's find_by dropped its alert silently.
#
# Set on ActiveJob::Base, not via config.active_job: Rails 8.1's railtie strips
# that key rather than apply it to Base, and ApplicationJob alone would miss
# ActionMailer::MailDeliveryJob, which is the job that failed.
ActiveSupport.on_load(:active_job) do
  self.enqueue_after_transaction_commit = true
end
