require "test_helper"

class IssuesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
  end

  test "index renders and paginates with numbered series nav" do
    # limit is 25 per page; create enough open issues to force a second page.
    30.times do |i|
      Issue.create!(
        project_id: @project.id, fingerprint: "fp-#{i}", title: "Boom #{i}",
        exception_type: "RuntimeError", count: 1,
        first_seen: Time.current, last_seen: i.seconds.ago, status: :open
      )
    end

    get project_issues_url(@project.slug)
    assert_response :success
    # Numbered page link to page 2 plus the current-page marker.
    assert_select "a[rel=next]", 1
    assert_select "nav[aria-label=Pagination] span[aria-current=page]", 1
    assert_select "a", text: "2"

    get project_issues_url(@project.slug, page: 2)
    assert_response :success
    assert_select "a[rel=prev]", 1
  end

  test "index filters by environment and offers a dropdown once there are two" do
    both = create_issue("spans-envs", "SpansEnvs")
    staging_only = create_issue("staging-only", "StagingOnly")
    IssueFacet.reset_throttle!
    IssueFacet.harvest!(project_id: @project.id, issue_id: both.id, values: {environment: "production"})
    IssueFacet.harvest!(project_id: @project.id, issue_id: both.id, values: {environment: "staging"})
    IssueFacet.harvest!(project_id: @project.id, issue_id: staging_only.id, values: {environment: "staging"})

    get project_issues_url(@project.slug)
    assert_response :success
    assert_select "select[name=environment] option", text: "production"
    assert_select "select[name=environment] option", text: "staging"

    get project_issues_url(@project.slug, environment: "production")
    assert_response :success
    assert_select "h2", text: "SpansEnvs"
    assert_select "h2", text: "StagingOnly", count: 0
    # The chips show every environment the issue spans, not just the filtered one.
    assert_select "span", text: "staging"
  end

  test "index hides the environment dropdown when only one environment is known" do
    issue = create_issue("only-one", "OnlyOne")
    IssueFacet.reset_throttle!
    IssueFacet.harvest!(project_id: @project.id, issue_id: issue.id, values: {environment: "production"})

    get project_issues_url(@project.slug)
    assert_response :success
    assert_select "select[name=environment]", count: 0
  end

  test "the status tabs keep the selected environment" do
    issue = create_issue("keeps-env", "KeepsEnv")
    IssueFacet.reset_throttle!
    IssueFacet.harvest!(project_id: @project.id, issue_id: issue.id, values: {environment: "production"})
    IssueFacet.harvest!(project_id: @project.id, issue_id: issue.id, values: {environment: "staging"})

    get project_issues_url(@project.slug, environment: "staging")
    assert_response :success
    assert_select "a[href*='status=resolved'][href*='environment=staging']"
  end

  test "index offers resolve and ignore per open row, reopen once it has left the open tab" do
    issue = create_issue("row-actions", "RowActions")

    get project_issues_url(@project.slug)
    assert_response :success
    assert_select "form[action=?]", resolve_project_issue_path(@project.slug, issue)
    assert_select "form[action=?]", ignore_project_issue_path(@project.slug, issue)
    # A <form> inside an <a> is invalid HTML and swallows the button's click,
    # which is why the row is a div with a stretched link rather than an anchor.
    assert_select "a form", count: 0

    issue.resolved!
    get project_issues_url(@project.slug, status: "resolved")
    assert_response :success
    assert_select "form[action=?]", reopen_project_issue_path(@project.slug, issue)
    assert_select "form[action=?]", resolve_project_issue_path(@project.slug, issue), count: 0
  end

  test "resolving from the list returns to the list with its filters intact" do
    issue = create_issue("resolve-from-list", "ResolveFromList")
    list = project_issues_url(@project.slug, status: "open", page: 2)

    patch resolve_project_issue_url(@project.slug, issue), headers: {"HTTP_REFERER" => list}

    assert_redirected_to list
    assert_predicate issue.reload, :resolved?
  end

  test "status actions fall back to the issue page when there is nowhere to go back to" do
    issue = create_issue("no-referer", "NoReferer")

    patch ignore_project_issue_url(@project.slug, issue)

    assert_redirected_to project_issue_path(@project.slug, issue)
    assert_predicate issue.reload, :ignored?
  end

  private

  def create_issue(fingerprint, title)
    Issue.create!(
      project_id: @project.id, fingerprint: fingerprint, title: title,
      exception_type: "RuntimeError", count: 1,
      first_seen: Time.current, last_seen: Time.current, status: :open
    )
  end
end
