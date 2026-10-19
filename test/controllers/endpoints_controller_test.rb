require "test_helper"

class EndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
    # The timeline caches a window's figures by the hour it ends on, which
    # every test here shares.
    Rails.cache.clear
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

  # No requests in the window means no percentiles. They showed 0ms, in the
  # green of a fast endpoint, where the helpers already render N/A for nil.
  test "index shows N/A, not 0ms, when the window has no requests" do
    get project_endpoints_url(@project.slug)
    assert_response :success
    assert_select "div", text: "No transactions in this window."
    refute_match(/>\s*0ms\s*</, response.body)

    # A kind's own tab still draws its rows, with nothing to say in them.
    get project_endpoints_url(@project.slug, kind: "job")
    assert_response :success
    assert_select "[data-latency=job]", text: /N\/A p50/
    refute_match(/>\s*0ms\s*</, response.body)
  end

  test "detail shows N/A, not 0ms, for an endpoint with no requests in the window" do
    get detail_project_endpoints_url(@project.slug, name: "NoSuchController#show")

    assert_response :success
    assert_select "div.text-3xl", text: "N/A", count: 3
    refute_match(/>\s*0ms\s*</, response.body)
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

  # A click on the project timeline's Throughput, Latency or endpoint row opens
  # these pages for that bucket, as ?from=&to=.
  test "index lists only the window's endpoints and transactions" do
    hour = 3.hours.ago.beginning_of_hour
    inside = Array.new(3) { |i| txn("GET /x", hour + i.minutes, 100) }
    after = txn("GET /x", hour + 1.hour, 900)

    get project_endpoints_url(@project.slug, from: hour.iso8601, to: (hour + 1.hour).iso8601)
    assert_response :success
    assert_select "[data-endpoint]", 1
    assert_select "[data-endpoint] [data-count]", text: "3"
    inside.each { assert_select "a[href=?]", project_transaction_path(@project.slug, it) }
    assert_select "a[href=?]", project_transaction_path(@project.slug, after), count: 0
    assert_match hour.utc.strftime("%-d %b %H:%M"), response.body
  end

  # A 15-minute bucket, from the timeline's 6h window: the hourly rollups can
  # only answer for the whole hour, so the table reads the raw rows.
  test "index reads a window shorter than an hour from the raw transactions" do
    hour = 3.hours.ago.beginning_of_hour
    2.times { |i| txn("GET /x", hour + 20.minutes + i.seconds, 100) }
    txn("GET /x", hour + 40.minutes, 900)

    get project_endpoints_url(@project.slug, from: (hour + 15.minutes).iso8601, to: (hour + 30.minutes).iso8601)
    assert_response :success
    assert_select "[data-endpoint] [data-count]", text: "2"
  end

  test "index and detail list a window's transactions slowest first when asked" do
    hour = 3.hours.ago.beginning_of_hour
    slow = txn("GET /x", hour + 5.minutes, 2000)
    fast = txn("GET /x", hour + 10.minutes, 50)
    middling = txn("GET /x", hour + 20.minutes, 400)
    window = {from: hour.iso8601, to: (hour + 1.hour).iso8601}

    get project_endpoints_url(@project.slug, sort: "slowest", **window)
    assert_equal [slow, middling, fast].map(&:id), listed_transaction_ids

    get detail_project_endpoints_url(@project.slug, name: "GET /x", sort: "slowest", **window)
    assert_equal [slow, middling, fast].map(&:id), listed_transaction_ids

    get detail_project_endpoints_url(@project.slug, name: "GET /x", **window)
    assert_equal [middling, fast, slow].map(&:id), listed_transaction_ids
  end

  test "detail lists only the window's transactions and steps a window at a time" do
    hour = 3.hours.ago.beginning_of_hour
    inside = txn("GET /x", hour + 10.minutes, 100)
    before = txn("GET /x", hour - 10.minutes, 100)

    get detail_project_endpoints_url(@project.slug, name: "GET /x", from: hour.iso8601, to: (hour + 1.hour).iso8601)
    assert_response :success
    assert_equal [inside.id], listed_transaction_ids
    assert_select "a[href=?]", detail_project_endpoints_path(@project.slug, name: "GET /x",
      from: (hour - 1.hour).utc.iso8601, to: hour.utc.iso8601)
    assert_select "a[href=?]", detail_project_endpoints_path(@project.slug, name: "GET /x"), text: "last 24h"
    refute_equal [before.id], listed_transaction_ids
  end

  # The window arrows, the order buttons and the way back out are this page
  # with its query changed. Built with url_for(query), a ?host= or
  # ?script_name= in the query sent them to another site.
  test "index and detail link only to this site whatever the query says" do
    hour = 3.hours.ago.beginning_of_hour
    hostile = {host: "evil.example", script_name: "//evil.example", protocol: "javascript",
               from: hour.iso8601, to: (hour + 1.hour).iso8601}

    get project_endpoints_path(@project.slug), params: hostile
    assert_response :success
    assert_select "a[href^=?]", "#{project_endpoints_path(@project.slug)}?", text: "←"
    refute_match %r{href="[^"]*//evil\.example}, response.body
    refute_match %r{href="javascript:}, response.body

    get detail_project_endpoints_path(@project.slug), params: hostile.merge(name: "GET /x")
    assert_response :success
    assert_select "a[href^=?]", "#{detail_project_endpoints_path(@project.slug)}?", text: "Slowest"
    refute_match %r{href="[^"]*//evil\.example}, response.body
    refute_match %r{href="javascript:}, response.body
  end

  def create_web_and_job_traffic(job_rate: nil, web_rate: nil)
    Facet.where(project_id: @project.id).delete_all
    Facet.reset_throttle!
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "CoverDownloadJob", op: "queue.process")
    2.times do |i|
      @project.transactions.create!(transaction_id: "txn-web-#{i}", transaction_name: "ProductsController#show",
        op: "http.server", timestamp: 2.hours.ago, duration: 100, http_status: "200", sample_rate: web_rate)
    end
    @project.transactions.create!(transaction_id: "txn-job", transaction_name: "CoverDownloadJob",
      op: "queue.process", timestamp: 2.hours.ago, duration: 5000, sample_rate: job_rate)
  end

  test "index draws web requests and background jobs apart, each with its own rows" do
    create_web_and_job_traffic

    get project_endpoints_url(@project.slug)
    assert_response :success

    assert_select "nav[aria-label=Kind] a[aria-current=page]", text: /All\s+3/
    assert_select "nav[aria-label=Kind] a", text: /Web\s+2/
    assert_select "nav[aria-label=Kind] a", text: /Jobs\s+1/
    assert_select "nav[aria-label=Kind] a", text: /Other/, count: 0
    assert_select "[data-signal=web] [data-count]", text: "2"
    assert_select "[data-signal=job] [data-count]", text: "1"
    assert_select "#kind-web", text: /web requests/
    assert_select "#kind-job", text: /background jobs/
    assert_select "[data-endpoint=?]", "ProductsController#show"
    assert_select "[data-endpoint=?]", "CoverDownloadJob"
  end

  test "the jobs tab draws only the jobs, in the timeline and the feed" do
    create_web_and_job_traffic

    get project_endpoints_url(@project.slug, kind: "job")
    assert_response :success

    assert_select "nav[aria-label=Kind] a[aria-current=page]", text: /Jobs\s+1/
    assert_select "[data-signal=job] [data-count]", text: "1"
    assert_select "[data-latency=job]", text: /5\.\d+s p50/
    assert_select "[data-signal=web]", count: 0
    assert_select "[data-endpoint=?]", "CoverDownloadJob"
    assert_select "[data-endpoint=?]", "ProductsController#show", count: 0
    assert_equal [@project.transactions.find_by!(transaction_id: "txn-job").id], listed_transaction_ids
  end

  test "the web tab leaves the jobs out of its percentiles" do
    create_web_and_job_traffic

    get project_endpoints_url(@project.slug, kind: "web")
    assert_response :success
    assert_select "[data-latency=web]", text: /p99 10\dms/
    assert_select "[data-endpoint=?]", "CoverDownloadJob", count: 0
  end

  # Booko samples requests at 1% and jobs at 10%. As recorded, the two
  # requests' 200ms is 4% of the time beside the one job's 5s; scaled up, it's
  # 20s beside 50s.
  test "each kind's share of the time is scaled by its sample rate" do
    create_web_and_job_traffic(web_rate: 0.01, job_rate: 0.1)

    get project_endpoints_url(@project.slug)
    assert_response :success
    assert_select "#kind-web", text: /29% of it/
    assert_select "#kind-job", text: /71% of it/
  end

  test "an unknown kind reads as all of them" do
    create_web_and_job_traffic

    get project_endpoints_url(@project.slug, kind: "bogus")
    assert_response :success
    assert_select "nav[aria-label=Kind] a[aria-current=page]", text: /All\s+3/
  end

  private

  def txn(name, at, duration)
    @project.transactions.create!(transaction_id: SecureRandom.uuid, transaction_name: name, timestamp: at, duration: duration)
  end

  # The transactions the page links to, in the order it lists them.
  def listed_transaction_ids
    response.body.scan(%r{/projects/#{@project.slug}/transactions/(\d+)}).flatten.map(&:to_i).uniq
  end
end
