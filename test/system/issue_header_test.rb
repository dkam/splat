require "application_system_test_case"

# The issue header holds a long title alongside the status badge and action
# buttons, and the issues list rows hold one alongside a sparkline and counts.
# Whether they collide or overflow is a question of rendered geometry, which
# only a real browser can answer, so this measures the boxes, not the markup.
class IssueHeaderTest < ApplicationSystemTestCase
  # Ruby's error_highlight appends the offending line, and a caret row under it,
  # to the exception message — so a real title is often long and multi-line.
  TITLE = <<~TITLE.chomp
    Failed to instantiate job, class `JunkSourceProbeJob` doesn't exist (ActiveJob::UnknownJobClassError)

            raise UnknownJobClassError, job_data["job_class"] unless job_class
            ^^^^^
  TITLE

  setup do
    @project = projects(:one)
    @issue = Issue.create!(
      project: @project, fingerprint: "issue-header-test", title: TITLE,
      exception_type: "ActiveJob::UnknownJobClassError", count: 4,
      first_seen: 1.hour.ago, last_seen: 15.minutes.ago, status: :open
    )
  end

  teardown do
    page.current_window.resize_to(1400, 1400)
  end

  [390, 940].each do |width|
    test "a long title stays clear of the status and actions at #{width}px" do
      page.current_window.resize_to(width, 900)
      visit project_issue_path(@project.slug, @issue)

      heading = rect("h1")
      %w[#issue-status #issue-actions].each do |selector|
        refute overlap?(heading, rect(selector)),
          "h1 #{heading.inspect} overlaps #{selector} #{rect(selector).inspect}"
      end
    end
  end

  test "the issues list fits a phone without scrolling sideways" do
    page.current_window.resize_to(390, 900)
    visit project_issues_path(@project.slug)
    find("h2", text: "Failed to instantiate job")

    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_equal 0, overflow, "the page is #{overflow}px wider than the viewport"
  end

  private

  def rect(selector)
    find(selector)
    page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")
  end

  def overlap?(a, b)
    a["left"] < b["right"] && b["left"] < a["right"] &&
      a["top"] < b["bottom"] && b["top"] < a["bottom"]
  end
end
