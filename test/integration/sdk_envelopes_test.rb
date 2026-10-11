require "test_helper"

# Envelopes recorded from real Sentry SDKs, through the whole ingest path: the
# endpoint, posted as the SDK posted them; the queue; the consumer; then the
# pages and MCP tools that show the result. Every SDK runs the same four
# scenarios — script/sdk_envelopes/README.md says what they are and how to
# record them again.
class SdkEnvelopesTest < ActionDispatch::IntegrationTest
  FIXTURES = Rails.root.join("test/fixtures/files/sdk_envelopes")
  ENCODINGS = {".gz" => "gzip", ".br" => "br", ".zst" => "zstd", ".deflate" => "deflate"}.freeze

  def self.md5(text) = Digest::MD5.hexdigest(text)

  # What each SDK's events come out as, in its own spelling: the exception
  # types, and the issue fingerprints that name the function in your code.
  # `file` is how the stack trace shows that function's file.
  SDKS = {
    "ruby" => {
      raised: "CheckoutError", cause: "CardNotFound", file: "lib/checkout.rb",
      chained: "CheckoutError::Object::charge",
      library_error: ["JSON::ParserError::Object::parse_order", "JSON::ParserError::Object::parse_refund"]
    },
    "python" => {
      raised: "CheckoutError", cause: "CardNotFound", file: "checkout.py",
      chained: "CheckoutError::__main__::charge",
      library_error: ["JSONDecodeError::__main__::parse_order", "JSONDecodeError::__main__::parse_refund"]
    },
    "node" => {
      raised: "CheckoutError", cause: "CardNotFound", file: "/app/checkout.js",
      chained: "CheckoutError::checkout::charge",
      library_error: ["SyntaxError::checkout::parseOrder", "SyntaxError::checkout::parseRefund"]
    },
    # A Go error carries no stack; sentry-go records where it was captured,
    # here a closure in main.
    "go" => {
      raised: "*main.CheckoutError", cause: "*main.CardNotFound", file: "/app/main.go",
      chained: "*main.CheckoutError::main::func1",
      library_error: ["*json.SyntaxError::main::parseOrder", "*json.SyntaxError::main::parseRefund"]
    },
    # sentry-java marks no frame as your code unless configured to, so the
    # whole stack stands in.
    "java" => {
      raised: "CheckoutError", cause: "CardNotFound", file: "Checkout.java",
      chained: /\ACheckoutError::\h{32}\z/,
      library_error: [/\ANumberFormatException::\h{32}\z/, /\ANumberFormatException::\h{32}\z/]
    },
    # sentry-php sends json_decode as a frame of its own at its caller's line.
    "php" => {
      raised: "CheckoutError", cause: "CardNotFound", file: "/checkout.php",
      chained: "CheckoutError::/checkout.php::charge",
      library_error: ["JsonException::/checkout.php::parse_order", "JsonException::/checkout.php::parse_refund"]
    },
    "dotnet" => {
      raised: "Example.CheckoutError", cause: "Example.CardNotFound", file: "Checkout.cs",
      chained: "Example.CheckoutError::Checkout.cs::void Checkout.Charge(string cardId)",
      library_error: [
        "System.Text.Json.JsonException::Checkout.cs::JsonElement Checkout.ParseOrder(string body)",
        "System.Text.Json.JsonException::Checkout.cs::JsonElement Checkout.ParseRefund(string body)"
      ]
    },
    # sentry-rust sends no stack trace by default, so an error groups by its
    # type and message — and the two parse errors can't be told apart.
    "rust" => {
      raised: "CheckoutError", cause: "CardNotFound", file: nil,
      chained: "CheckoutError::#{md5("checkout failed")}",
      library_error: ["Error::#{md5("EOF while parsing an object at line ? column ?")}"]
    }
  }.freeze

  setup do
    @project = Project.create!(name: "SDKs", slug: "sdks", public_key: "sdk-envelopes")
  end

  SDKS.each do |sdk, expected|
    test "#{sdk}: a chained exception, with a breadcrumb and a binary attachment" do
      event = ingest(sdk, "chained").sole

      assert_equal expected[:raised], event.exception_type
      assert_equal [expected[:cause]], event.causes.map { it["type"] }
      assert_match fingerprint(expected[:chained]), event.issue.fingerprint

      page = assert_shown(event)
      assert_includes page, "charging card 4412"
      assert_includes page, expected[:file] if expected[:file]
    end

    test "#{sdk}: a library error raised from two places in your code" do
      events = ingest(sdk, "library_error")
      fingerprints = events.map { it.issue.fingerprint }.uniq.sort

      assert_equal expected[:library_error].size, fingerprints.size
      expected[:library_error].zip(fingerprints) { |want, got| assert_match fingerprint(want), got }
      events.each { assert_shown(it) }
    end

    test "#{sdk}: a message differing only in a number is one issue" do
      events = ingest(sdk, "message")

      assert_equal ["Card 4412 declined", "Card 9001 declined"], events.map(&:message).sort
      assert_equal 1, events.map(&:issue_id).uniq.size
      events.each { assert_shown(it) }
    end

    # Span timestamps arrive as epoch seconds (Ruby, Java, PHP), as ISO 8601
    # strings (Python, Go, .NET), or one of each (Rust: start, then end).
    test "#{sdk}: a transaction with two queries, timed by its spans" do
      skip "@sentry/node 11 streams spans (span v2 items) instead of sending a transaction" if sdk == "node"
      transaction = ingest_transactions(sdk).sole

      assert_equal ["POST /checkout", "http.server"], [transaction.transaction_name, transaction.op]
      # Each query is held open 10 ms, one after the other.
      assert_operator transaction.db_time, :>=, 20
      assert_operator transaction.duration, :>=, transaction.db_time
      queries = transaction.query_patterns.fetch("SELECT * FROM cards WHERE id = ?")
      assert_equal 2, queries["count"]
      assert_operator queries["total_time_ms"], :>=, 20

      spans = SpanTree.find_by!(project_id: @project.id, transaction_id: transaction.transaction_id).tree["spans"]
      assert_equal ["POST /checkout", "SELECT * FROM cards WHERE id = ?", "SELECT * FROM cards WHERE id = ?"],
        spans.map { it["description"] }
      starts = spans.map { Time.iso8601(it["ts"]) }
      assert_equal starts.sort, starts
      assert_operator starts.last - starts[1], :>=, 0.01

      get project_transaction_url(@project.slug, transaction)
      assert_response :success
      [SplatMcpTools.new.get_transaction("transaction_id" => transaction.transaction_id),
        SplatMcpTools.new.get_transaction_spans("transaction_id" => transaction.transaction_id)].each do |result|
        assert_not result.error?, result.content.inspect
      end
    end
  end

  private

  # The events a scenario queues, through the call the event consumer makes.
  def ingest(sdk, scenario)
    queued(sdk, scenario, Ingest::Tuber::EVENTS_TUBE).map do
      Event.create_from_sentry_payload!(it["event_id"], it["payload"], @project)
    end
  end

  # Through the consumer itself, which also builds the span tree and retries
  # a job that raises.
  def ingest_transactions(sdk)
    job = Struct.new(:body, :outcome) do
      def delete = self.outcome = :done
      def release(**) = self.outcome = :retried
      def stats = Struct.new(:releases).new(0)
    end
    jobs = queued(sdk, "transaction", Ingest::Tuber::TRANSACTIONS_TUBE).map { job.new(JSON.generate(it)) }
    Ingest::TransactionConsumer.new.send(:process_batch, jobs)

    assert_equal [:done], jobs.map(&:outcome).uniq, "The consumer failed a job; log/test.log says why"
    Transaction.where(project: @project).to_a
  end

  # What a scenario's envelopes, posted as recorded, compressed or not, put on
  # the tube — after a round trip through JSON, as a job on the queue takes.
  def queued(sdk, scenario, tube)
    files = Dir[FIXTURES.join(sdk, "#{scenario}-*")].sort
    assert files.any?, "No #{sdk} #{scenario} envelopes: run script/sdk_envelopes/capture #{sdk}"

    jobs = []
    queue = ->(to, job, **) { jobs << JSON.parse(JSON.generate(job)) if to == tube }
    with_stub(Ingest::Tuber, :put, queue) do
      files.each do |file|
        headers = {"Content-Type" => "application/x-sentry-envelope", "Content-Encoding" => ENCODINGS[File.extname(file)]}
        post "/api/#{@project.slug}/envelope/?sentry_key=#{@project.public_key}", params: File.binread(file), headers: headers.compact
        assert_response :success
      end
    end
    jobs
  end

  # The event's page, its issue's page, and the MCP tools that describe them
  # all render. Returns the event page.
  def assert_shown(event)
    get project_issue_url(@project.slug, event.issue)
    assert_response :success
    [SplatMcpTools.new.get_event("event_id" => event.event_id), SplatMcpTools.new.get_issue("issue_id" => event.issue_id)].each do |result|
      assert_not result.error?, result.content.inspect
    end

    get project_event_url(@project.slug, event)
    assert_response :success
    response.body
  end

  def fingerprint(expected) = expected.is_a?(Regexp) ? expected : /\A#{Regexp.escape(expected)}\z/
end
