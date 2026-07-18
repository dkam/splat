require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
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
