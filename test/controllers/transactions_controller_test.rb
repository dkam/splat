require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
  end

  # Same as events: the SDK's transaction_id is the URL, a row id still opens.
  test "a transaction's URL carries its transaction_id, and a link by row id still opens it" do
    txn = @project.transactions.create!(transaction_id: SecureRandom.hex(16),
      transaction_name: "AddressedController#show", timestamp: Time.current, duration: 12)

    assert_equal "/projects/#{@project.slug}/transactions/#{txn.transaction_id}",
      project_transaction_path(@project.slug, txn)
    [txn.transaction_id, txn.id].each do |id|
      get project_transaction_url(@project.slug, id)
      assert_response :success
      assert_match "AddressedController#show", response.body
    end

    get project_transaction_url(@project.slug, txn, format: :json)
    assert_equal txn.transaction_id, response.parsed_body["transaction_id"]

    get project_transaction_url(projects(:two).slug, txn.transaction_id)
    assert_response :not_found
  end

  test "show lists the errors thrown during the request" do
    trace = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
    txn = @project.transactions.create!(
      transaction_id: "txn-errs", transaction_name: "BooksController#show",
      timestamp: Time.current, duration: 240, trace_id: trace
    )
    event = Event.create_from_sentry_payload!(
      "evt-on-txn",
      {"exception" => {"values" => [{"type" => "NoMethodError", "value" => "undefined method"}]},
       "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    get project_transaction_url(@project.slug, txn)
    assert_response :success
    assert_select "a[href=?]", project_event_path(@project.slug, event), text: /NoMethodError/
  end

  test "show lists a request's errors by their message line, without the error_highlight snippet" do
    trace = "1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e"
    txn = @project.transactions.create!(
      transaction_id: "txn-highlighted", transaction_name: "BooksController#show",
      timestamp: Time.current, duration: 240, trace_id: trace
    )
    message = "undefined local variable or method 'job' for main\n\n    job.perform\n    ^^^"
    event = Event.create_from_sentry_payload!(
      "evt-highlighted-on-txn",
      {"exception" => {"values" => [{"type" => "NameError", "value" => message}]},
       "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    get project_transaction_url(@project.slug, txn)
    assert_response :success
    assert_select "a[href=?]", project_event_path(@project.slug, event),
      text: "NameError — undefined local variable or method 'job' for main"
  end

  test "show renders cleanly for a transaction with no linked errors" do
    txn = @project.transactions.create!(
      transaction_id: "txn-clean", transaction_name: "Test",
      timestamp: Time.current, duration: 100
    )

    get project_transaction_url(@project.slug, txn)
    assert_response :success
    assert_select "h2", text: /error.* in this request/, count: 0
  end
end
