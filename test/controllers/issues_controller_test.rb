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
    assert_select "span[aria-current=page]", 1
    assert_select "a", text: "2"

    get project_issues_url(@project.slug, page: 2)
    assert_response :success
    assert_select "a[rel=prev]", 1
  end
end
