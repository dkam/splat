# frozen_string_literal: true

class ConfigurationPreview < ActionMailer::Preview
  def custom_from_address
    # Set custom from address for preview
    ENV['SPLAT_EMAIL_FROM'] = 'alerts@splat-monitoring.com'

    project = Project.new(name: "Test Project", slug: "test")
    issue = Issue.new(
      title: "Test issue for custom configuration",
      fingerprint: "test::config::line_1",
      project: project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    email = IssueMailer.new_issue(issue)

    # Clean up environment variable
    ENV.delete('SPLAT_EMAIL_FROM')

    email
  end

  def custom_admin_emails
    # Set custom admin emails for preview
    ENV['SPLAT_ADMIN_EMAILS'] = 'dev-team@example.com, ops@example.com'

    project = Project.new(name: "Multi-team Project", slug: "multi-team")
    issue = Issue.new(
      title: "Cross-team notification test",
      fingerprint: "cross_team::notification::line_42",
      project: project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    email = IssueMailer.new_issue(issue)

    # Clean up environment variable
    ENV.delete('SPLAT_ADMIN_EMAILS')

    email
  end

  def custom_host_configuration
    # Set custom host for preview
    ENV['SPLAT_HOST'] = 'splat.company.com:443'

    project = Project.new(name: "Company Production", slug: "company-prod")
    issue = Issue.new(
      title: "Production issue with custom host",
      fingerprint: "production::custom_host::line_15",
      project: project,
      status: :open,
      first_seen: 1.hour.ago,
      last_seen: 1.hour.ago
    )

    email = IssueMailer.issue_reopened(issue)

    # Clean up environment variable
    ENV.delete('SPLAT_HOST')

    email
  end
end