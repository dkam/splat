# The URL of an issue's page, for alerts sent outside a request: SPLAT_HOST,
# https unless it's localhost. nil when there's nothing to link to.
module IssueLink
  module_function

  def url(issue)
    return nil unless issue.persisted? && issue.project&.persisted?

    host = ENV.fetch("SPLAT_HOST", "localhost:3000")
    scheme = host.include?("localhost") ? "http" : "https"
    # Routes nest issues under projects with `param: :slug`, and Project doesn't
    # override to_param — pass the slug explicitly so the URL is routable.
    Rails.application.routes.url_helpers.project_issue_url(
      issue.project.slug, issue, host: host, protocol: scheme
    )
  rescue
    nil
  end
end
