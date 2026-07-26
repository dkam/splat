require "test_helper"

class EndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
  end

  test "detail labels every bucket of the p95 trend for hover" do
    3.times do |i|
      @project.transactions.create!(
        transaction_id: "txn-trend-#{i}", transaction_name: "ProductsController#show",
        timestamp: 2.hours.ago, duration: 100 + i
      )
    end

    get detail_project_endpoints_url(@project.slug, name: "ProductsController#show")
    assert_response :success

    # One hover target per bucket, each carrying its own tooltip. The <title>
    # elements are the JS-off fallback; the Stimulus controller lifts them into
    # an instant tooltip.
    assert_select "[data-controller=sparkline-tooltip] svg"
    assert_select "rect.sparkline-hover", 168
    assert_select "rect.sparkline-hover title", minimum: 168
    assert_select "rect.sparkline-hover title", text: /no traffic/
    assert_select "rect.sparkline-hover title", text: /p95 10\dms/
  end

  test "detail shows the trend's best and peak hour" do
    @project.transactions.create!(
      transaction_id: "txn-peak", transaction_name: "SlowController#index",
      timestamp: 1.hour.ago, duration: 900
    )

    get detail_project_endpoints_url(@project.slug, name: "SlowController#index")
    assert_response :success
    assert_select "div", text: /Best hour/
    assert_select "div", text: /Peak/
  end
end
