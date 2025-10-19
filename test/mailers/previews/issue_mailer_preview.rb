# frozen_string_literal: true

class IssueMailerPreview < ActionMailer::Preview
  def new_issue
    project = Project.new(name: "My Web Application", slug: "my-web-app")
    issue = Issue.new(
      title: "NoMethodError: undefined method `email' for nil:NilClass",
      fingerprint: "nomethoderror::user_controller::line_42",
      exception_type: "NoMethodError",
      project: project,
      status: :open,
      first_seen: 2.hours.ago,
      last_seen: 2.hours.ago,
      count: 1
    )

    IssueMailer.new_issue(issue)
  end

  def new_issue_with_exception_type
    project = Project.new(name: "API Service", slug: "api-service")
    issue = Issue.new(
      title: "ActiveRecord::RecordNotFound: Couldn't find User with 'id'=12345",
      fingerprint: "activerecord::recordnotfound::users_controller::line_15",
      exception_type: "ActiveRecord::RecordNotFound",
      project: project,
      status: :open,
      first_seen: 30.minutes.ago,
      last_seen: 30.minutes.ago,
      count: 3
    )

    IssueMailer.new_issue(issue)
  end

  def new_issue_simple_message
    project = Project.new(name: "Background Job", slug: "background-job")
    issue = Issue.new(
      title: "Job failed: Connection timeout to database",
      fingerprint: "timeout::job_processor::line_89",
      exception_type: nil,
      project: project,
      status: :open,
      first_seen: 1.hour.ago,
      last_seen: 1.hour.ago,
      count: 5
    )

    IssueMailer.new_issue(issue)
  end

  def issue_reopened
    project = Project.new(name: "E-commerce Platform", slug: "ecommerce")
    issue = Issue.new(
      title: "PaymentGatewayError: Credit card processing failed",
      fingerprint: "payment_gateway_error::checkout_controller::line_78",
      exception_type: "PaymentGatewayError",
      project: project,
      status: :open,
      first_seen: 2.days.ago,
      last_seen: 10.minutes.ago,
      count: 15
    )

    IssueMailer.issue_reopened(issue)
  end

  def issue_reopened_high_frequency
    project = Project.new(name: "Mobile App Backend", slug: "mobile-api")
    issue = Issue.new(
      title: "Redis::CannotConnectError: Connection refused",
      fingerprint: "redis::cannotconnecterror::cache_service::line_23",
      exception_type: "Redis::CannotConnectError",
      project: project,
      status: :open,
      first_seen: 1.day.ago,
      last_seen: 5.minutes.ago,
      count: 127
    )

    IssueMailer.issue_reopened(issue)
  end

  def issue_reopened_critical
    project = Project.new(name: "Production Server", slug: "production")
    issue = Issue.new(
      title: "SystemExit: Critical system failure detected",
      fingerprint: "systemexit::kernel::line_1",
      exception_type: "SystemExit",
      project: project,
      status: :open,
      first_seen: 6.hours.ago,
      last_seen: 2.minutes.ago,
      count: 1
    )

    IssueMailer.issue_reopened(issue)
  end
end