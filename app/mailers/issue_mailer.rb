class IssueMailer < ApplicationMailer
  include Rails.application.routes.url_helpers

  def new_issue(issue)
    @issue = issue
    @project = issue.project
    @url = generate_issue_url(issue)

    mail(
      from: ENV.fetch('SPLAT_EMAIL_FROM', 'splat@example.com'),
      to: admin_emails,
      subject: "[Splat] New Issue: #{issue.title}"
    )
  end

  def issue_reopened(issue)
    @issue = issue
    @project = issue.project
    @url = generate_issue_url(issue)

    mail(
      from: ENV.fetch('SPLAT_EMAIL_FROM', 'splat@example.com'),
      to: admin_emails,
      subject: "[Splat] Issue Reopened: #{issue.title}"
    )
  end

  private

  def admin_emails
    ENV.fetch('SPLAT_ADMIN_EMAILS', 'admin@example.com').split(',').map(&:strip)
  end

  def mailer_host
    ENV.fetch('SPLAT_HOST', 'localhost:3000')
  end

  def default_url_options
    { host: mailer_host }
  end

  def generate_issue_url(issue)
    # Handle preview objects without IDs
    if issue.persisted? && issue.project&.persisted?
      project_issue_url(issue.project, issue, host: mailer_host)
    else
      # Generate a placeholder URL for previews
      "#{mailer_host}/projects/#{issue.project&.slug || 'preview-project'}/issues/#{issue.id || 'preview-issue'}"
    end
  end
end