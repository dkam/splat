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
      # Four digits: the count is the widest thing in a list row's top line.
      exception_type: "ActiveJob::UnknownJobClassError", count: 1432,
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

  [390, 940].each do |width|
    test "an event's long message stays clear of its buttons at #{width}px" do
      event = Event.create_from_sentry_payload!(
        "evt-header-test",
        {"exception" => {"values" => [{"type" => "ActiveJob::UnknownJobClassError", "value" => TITLE}]},
         "environment" => "production", "timestamp" => 15.minutes.ago.iso8601},
        @project
      )
      page.current_window.resize_to(width, 900)
      visit project_event_path(@project.slug, event)

      heading = rect("h1")
      [find_link("View Issue"), find_button("Delete Event")].each do |button|
        refute overlap?(heading, rect(button)),
          "h1 #{heading.inspect} overlaps #{button.text} #{rect(button).inspect}"
      end
      # The buttons used to be pushed off the right edge rather than over the title.
      assert_equal 0, horizontal_overflow, "the page is #{horizontal_overflow}px wider than the viewport"
    end
  end

  # A phone is too narrow for the code line, and wrapping it left the carets
  # several lines below, under nothing in particular.
  test "an event's error_highlight carets stay under the code on a phone" do
    event = Event.create_from_sentry_payload!(
      "evt-carets-test",
      {"exception" => {"values" => [{"type" => "ActiveJob::UnknownJobClassError", "value" => TITLE}]},
       "timestamp" => 15.minutes.ago.iso8601},
      @project
    )
    page.current_window.resize_to(390, 900)
    visit project_event_path(@project.slug, event)

    {
      "the snippet under the heading" => find("#event-message-detail"),
      "the exception box" => find("h2", text: "ActiveJob::UnknownJobClassError").find(:xpath, "..")
    }.each do |where, node|
      code, carets = %w[raise ^^^^^].map { |text| text_rect(node, text) }
      assert_in_delta code["left"], carets["left"], 1, "in #{where}, the carets start in another column from the code"
      assert_in_delta code["bottom"], carets["top"], code["height"] / 2,
        "in #{where}, the carets #{carets.inspect} aren't on the line under the code #{code.inspect}"
    end
  end

  # The sparkline, count and buttons sat beside the title and took a third of
  # the row from it, so a long message wrapped to three or four lines. The
  # issues list and the overview's recent issues share one row partial; both
  # pages are checked so a change made for one is seen on the other.
  {"issues list" => :project_issues_path, "project overview" => :project_path}.each do |where, path|
    test "an issue row on the #{where} gives its title the full width, below the counts and buttons" do
      page.current_window.resize_to(940, 900)
      visit public_send(path, @project.slug)

      heading = rect(find("h2, h3", text: "Failed to instantiate job"))
      resolve = rect(find("form[action$='/issues/#{@issue.id}/resolve'] button"))
      assert_operator heading["top"], :>=, resolve["bottom"],
        "the title #{heading.inspect} sits beside the buttons #{resolve.inspect}"
    end

    # Wrapping the top line put the count and buttons on a line of their own,
    # stranded at the left of the row.
    test "an issue row on the #{where} cuts a long exception type short rather than wrapping" do
      @issue.update!(exception_type: "ActionController::Redirecting::OpenRedirectError")
      page.current_window.resize_to(940, 900)
      visit public_send(path, @project.slug)

      id = rect(find("span", text: "##{@issue.id}", exact_text: true))
      resolve = rect(find("form[action$='/issues/#{@issue.id}/resolve'] button"))
      assert_operator resolve["top"], :<, id["bottom"],
        "the buttons #{resolve.inspect} wrapped below the id #{id.inspect}"
    end

    test "an issue row on the #{where} fits a phone without scrolling sideways" do
      page.current_window.resize_to(390, 900)
      visit public_send(path, @project.slug)
      find("h2, h3", text: "Failed to instantiate job")

      assert_equal 0, horizontal_overflow, "the page is #{horizontal_overflow}px wider than the viewport"
      # The row itself, too: the page only shows an overflow when the row's
      # spills past the viewport's edge, which a scrollbar can decide.
      row = find("a[href$='/issues/#{@issue.id}']").find(:xpath, "..")
      spill = page.evaluate_script("arguments[0].scrollWidth - arguments[0].clientWidth", row)
      assert_equal 0, spill, "the row's content is #{spill}px wider than the row"
    end
  end

  # The header is fixed, so its overflow doesn't scroll the page; it's just
  # cut off, taking the queue status and the sign-in controls with it.
  [390, 940].each do |width|
    test "the header's controls fit within it at #{width}px" do
      page.current_window.resize_to(width, 900)
      visit project_path(@project.slug)

      spill = page.evaluate_script("(h => h.scrollWidth - h.clientWidth)(document.querySelector('header'))")
      assert_equal 0, spill, "the header's content is #{spill}px wider than the header"
    end
  end

  # The row is one link stretched over it, and its issue link has to stay
  # clickable on top of that rather than underneath.
  test "a recent event on the overview opens the event, and its issue link the issue" do
    event = Event.create_from_sentry_payload!(
      "evt-overview-row",
      {"exception" => {"values" => [{"type" => "NoMethodError", "value" => "boom"}]},
       "timestamp" => Time.current.iso8601},
      @project
    )
    visit project_path(@project.slug)

    issue_link = find_link("Issue ##{event.issue.id}")
    issue_link.scroll_to(issue_link)
    assert_equal project_issue_path(@project.slug, event.issue), link_at(issue_link)
    row = find("a[href='#{project_event_path(@project.slug, event)}']").find(:xpath, "..")
    assert_equal project_event_path(@project.slug, event), link_at(row.find("h3", text: "boom"))
  end

  private

  # The href of the link a click at the middle of node lands on.
  def link_at(node)
    page.evaluate_script(<<~JS, node)
      ((node) => {
        const r = node.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return hit && hit.closest("a") && hit.closest("a").getAttribute("href");
      })(arguments[0])
    JS
  end

  def rect(selector_or_node)
    node = selector_or_node.is_a?(String) ? find(selector_or_node) : selector_or_node
    page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", node)
  end

  # Where the first occurrence of text inside node is drawn.
  def text_rect(node, text)
    page.evaluate_script(<<~JS, node, text)
      ((root, text) => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let n; (n = walker.nextNode());) {
          const i = n.data.indexOf(text);
          if (i < 0) continue;
          const range = document.createRange();
          range.setStart(n, i);
          range.setEnd(n, i + text.length);
          return range.getBoundingClientRect().toJSON();
        }
        return null;
      })(arguments[0], arguments[1])
    JS
  end

  def horizontal_overflow
    page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
  end

  def overlap?(a, b)
    a["left"] < b["right"] && b["left"] < a["right"] &&
      a["top"] < b["bottom"] && b["top"] < a["bottom"]
  end
end
