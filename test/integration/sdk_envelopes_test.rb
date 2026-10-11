require "test_helper"

# Envelopes recorded from real Sentry SDKs, through the whole ingest path: the
# endpoint, posted as the SDK posted them; the queue; the consumer; then the
# pages and MCP tools that show the result. Every SDK runs the same three
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
  end

  private

  # Posts a scenario's envelopes as recorded, compressed or not, and runs what
  # they queue through the consumer's own call — after a round trip through
  # JSON, as a job on the queue takes.
  def ingest(sdk, scenario)
    files = Dir[FIXTURES.join(sdk, "#{scenario}-*")].sort
    assert files.any?, "No #{sdk} #{scenario} envelopes: run script/sdk_envelopes/capture #{sdk}"

    jobs = []
    queue = ->(tube, job, **) { jobs << JSON.parse(JSON.generate(job)) if tube == Ingest::Tuber::EVENTS_TUBE }
    with_stub(Ingest::Tuber, :put, queue) do
      files.each do |file|
        headers = {"Content-Type" => "application/x-sentry-envelope", "Content-Encoding" => ENCODINGS[File.extname(file)]}
        post "/api/#{@project.slug}/envelope/?sentry_key=#{@project.public_key}", params: File.binread(file), headers: headers.compact
        assert_response :success
      end
    end

    jobs.map { Event.create_from_sentry_payload!(it["event_id"], it["payload"], @project) }
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
