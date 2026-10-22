require "application_system_test_case"

# An endpoint row's figures sit in columns under a header naming them. The
# header was one string, right-aligned, so only its last word landed over its
# column. Whether a label sits over its figures is rendered geometry, so this
# measures where the text is drawn.
class EndpointColumnsTest < ApplicationSystemTestCase
  setup do
    @project = projects(:one)
    Rails.cache.clear
    # Figures of different widths, so a label can't line up with one row by luck.
    [120, 340, 2_400].each_with_index { |ms, i| txn("ProductsController#show", (i + 2).hours.ago, ms) }
    40.times { |i| txn("Api::V1::BulkDataController#index", (i * 20 + 30).minutes.ago, 26) }
    page.current_window.resize_to(940, 900)
  end

  teardown do
    page.current_window.resize_to(1400, 1400)
  end

  test "the performance page's column labels sit over their figures" do
    visit project_endpoints_path(@project.slug)

    assert_columns_line_up find("#kind-web"), %w[time count p50 p95], all("[data-endpoint]")
  end

  test "the overview's column labels sit over their figures" do
    visit project_path(@project.slug, window: "24h")

    head = find("span", text: /\Awhere the time went\z/i).find(:xpath, "..")
    rows = ["ProductsController#show", "Api::V1::BulkDataController#index"].map { find("a[title='#{it}']").find(:xpath, "../..") }
    assert_columns_line_up head, %w[time p95], rows
  end

  private

  def txn(name, at, duration)
    @project.transactions.create!(transaction_id: SecureRandom.uuid, transaction_name: name, timestamp: at, duration: duration)
  end

  # Each label's right edge against the right edge of the figure under it in
  # every row: the figures are right-aligned, so their labels should be too.
  def assert_columns_line_up(head, labels, rows)
    assert_equal 2, rows.size
    rows.each do |row|
      figures = figure_rights(row)
      assert_equal labels.size, figures.size, "expected a figure per label in #{row.text.inspect}"
      labels.zip(figures).each do |label, figure|
        drawn = text_right(head, label)
        assert_in_delta figure, drawn, 1.5,
          "the #{label} label ends at #{drawn.round(1)}, its figures at #{figure.round(1)} (#{row.text.inspect})"
      end
    end
  end

  # Where the text of each figure in a row's last cell ends.
  def figure_rights(row)
    page.evaluate_script(<<~JS, row)
      (row => [...row.lastElementChild.querySelectorAll("span")].map(span => {
        const range = document.createRange();
        range.selectNodeContents(span);
        return range.getBoundingClientRect().right;
      }))(arguments[0])
    JS
  end

  # Where a label ends in the header's last cell, the one over the figures:
  # the aside before it says "time" and "p95" too.
  def text_right(head, text)
    page.evaluate_script(<<~JS, head, text)
      ((head, text) => {
        const walker = document.createTreeWalker(head.lastElementChild, NodeFilter.SHOW_TEXT);
        for (let n; (n = walker.nextNode());) {
          const i = n.data.indexOf(text);
          if (i < 0) continue;
          const range = document.createRange();
          range.setStart(n, i);
          range.setEnd(n, i + text.length);
          return range.getBoundingClientRect().right;
        }
        return null;
      })(arguments[0], arguments[1])
    JS
  end
end
