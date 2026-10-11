require "test_helper"

# What makes two events one issue (Issue::Fingerprint), through the real
# ingest path.
class IssueGroupingTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Grouping", slug: "grouping", public_key: "grouping-key")
  end

  # ---- Exceptions: the type, and the function in your code it came from

  test "an error raised inside a gem groups by the call site in your code" do
    books = ingest(exception_payload("ActiveRecord::RecordNotFound",
      frame("active_record/core.rb", 253, "find", "ActiveRecord::Core::ClassMethods", app: false),
      frame("app/controllers/books_controller.rb", 10, "show", "BooksController")))
    authors = ingest(exception_payload("ActiveRecord::RecordNotFound",
      frame("active_record/core.rb", 253, "find", "ActiveRecord::Core::ClassMethods", app: false),
      frame("app/controllers/authors_controller.rb", 8, "show", "AuthorsController")))

    assert_not_equal books.issue_id, authors.issue_id
  end

  test "an issue survives the line it's raised on moving" do
    before_edit = ingest(exception_payload("NoMethodError", frame("app/models/book.rb", 12, "title", "Book")))
    after_edit = ingest(exception_payload("NoMethodError", frame("app/models/book.rb", 15, "title", "Book")))

    assert_equal before_edit.issue_id, after_edit.issue_id
  end

  # Rails names a compiled template's method after its path plus a number that
  # differs in every process — measured from sentry-ruby 7.0.0 on Rails 8.
  test "a template error groups the same in every process" do
    first = ingest(exception_payload("NoMethodError",
      frame("app/views/books/show.html.erb", 2, "_app_views_books_show_html_erb__1033375417407740265_9816")))
    after_restart = ingest(exception_payload("NoMethodError",
      frame("app/views/books/show.html.erb", 2, "_app_views_books_show_html_erb__2552903438630504205_9816")))

    assert_equal first.issue_id, after_restart.issue_id
  end

  # sentry-ruby reports a core method written in C — Hash#fetch, Integer#/ — as
  # a frame of its own at its caller's file and line, so as your code. So does
  # sentry-php for a built-in like json_decode. Measured from sentry-ruby 7.0.0.
  test "an error raised by a core method groups by the function in your code that called it" do
    price = ingest(exception_payload("KeyError",
      frame("app/models/book.rb", 4, "fetch", "Hash"),
      frame("app/models/book.rb", 4, "price", "Book"),
      frame("app/controllers/books_controller.rb", 10, "show", "BooksController")))
    stock = ingest(exception_payload("KeyError",
      frame("app/models/book.rb", 9, "fetch", "Hash"),
      frame("app/models/book.rb", 9, "stock", "Book"),
      frame("app/controllers/books_controller.rb", 11, "show", "BooksController")))

    assert_equal "KeyError::Book::price", price.issue.fingerprint
    assert_equal "KeyError::Book::stock", stock.issue.fingerprint
  end

  # As Sentry does: without a frame of your code to anchor on, the whole stack.
  test "with no frame in your code, the whole stack stands in, without line numbers" do
    before_upgrade = ingest(exception_payload("Net::ReadTimeout",
      frame("net/protocol.rb", 229, "rbuf_fill", "Net::BufferedIO", app: false),
      frame("net/http.rb", 1500, "request", "Net::HTTP", app: false)))
    after_upgrade = ingest(exception_payload("Net::ReadTimeout",
      frame("net/protocol.rb", 231, "rbuf_fill", "Net::BufferedIO", app: false),
      frame("net/http.rb", 1512, "request", "Net::HTTP", app: false)))
    other_caller = ingest(exception_payload("Net::ReadTimeout",
      frame("net/protocol.rb", 229, "rbuf_fill", "Net::BufferedIO", app: false),
      frame("net/smtp.rb", 600, "deliver", "Net::SMTP", app: false)))

    assert_equal before_upgrade.issue_id, after_upgrade.issue_id
    assert_not_equal before_upgrade.issue_id, other_caller.issue_id
  end

  # As Sentry does: sentry-rust sends none by default. By type alone, every
  # serde_json::Error in an app — type "Error" — was one issue.
  test "an exception with no stack trace groups by its type and message, without the numbers" do
    eof = ingest(exception_payload("Error").merge("exception" => {"values" => [{"type" => "Error", "value" => "EOF while parsing an object at line 1 column 1"}]}))
    eof_elsewhere = ingest(exception_payload("Error").merge("exception" => {"values" => [{"type" => "Error", "value" => "EOF while parsing an object at line 3 column 14"}]}))
    refused = ingest(exception_payload("Error").merge("exception" => {"values" => [{"type" => "Error", "value" => "Connection refused (os error 111)"}]}))

    assert_equal eof.issue_id, eof_elsewhere.issue_id
    assert_not_equal eof.issue_id, refused.issue_id
  end

  # ---- An SDK's own fingerprint

  test "{{ default }} in an SDK fingerprint stands for Splat's own" do
    tenant = ["{{ default }}", "tenant-7"]
    book = ingest(exception_payload("NoMethodError", frame("app/models/book.rb", 12, "title", "Book"), fingerprint: tenant))
    author = ingest(exception_payload("NoMethodError", frame("app/models/author.rb", 4, "name", "Author"), fingerprint: tenant))
    other_tenant = ingest(exception_payload("NoMethodError", frame("app/models/book.rb", 12, "title", "Book"), fingerprint: ["{{default}}", "tenant-8"]))

    assert_not_equal book.issue_id, author.issue_id
    assert_not_equal book.issue_id, other_tenant.issue_id
    assert_no_match(/\{\{/, book.issue.fingerprint)
  end

  test "an SDK fingerprint sent as a string rather than a list is used" do
    event = ingest({"message" => "checkout failed", "fingerprint" => "checkout", "timestamp" => "2026-10-11T08:00:00Z"})

    assert_equal "checkout", event.issue.fingerprint
  end

  # ---- Messages: the text, without the numbers and ids that vary

  test "messages differing only in numbers are one issue" do
    first = ingest(message_payload("Timeout after 3021ms for user 4412"))
    second = ingest(message_payload("Timeout after 2987ms for user 18"))

    assert_equal first.issue_id, second.issue_id
    assert_equal "Timeout after 3021ms for user 4412", first.issue.title
  end

  test "messages differing only in a UUID or a hex id are one issue" do
    uuid_a = ingest(message_payload("Import 9f8c1a2e-1b2c-4d5e-8f90-a1b2c3d4e5f6 failed"))
    uuid_b = ingest(message_payload("Import 0e1d2c3b-4a59-4687-9a0b-c1d2e3f4a5b6 failed"))
    hex_a = ingest(message_payload("Worker 0x7f3a2c0041d8 stalled on 3f9a1c2b7e"))
    hex_b = ingest(message_payload("Worker 0x55d5c3a0 stalled on 0a9b8c7d6e"))

    assert_equal uuid_a.issue_id, uuid_b.issue_id
    assert_equal hex_a.issue_id, hex_b.issue_id
  end

  test "messages differing in words are still different issues" do
    declined = ingest(message_payload("Card 4412 declined"))
    expired = ingest(message_payload("Card 4412 expired"))

    assert_not_equal declined.issue_id, expired.issue_id
  end

  # ---- Issues grouped by Splat 1.19.4 and earlier carry over, re-keyed

  test "an exception issue grouped the 1.19.4 way takes the next event" do
    payload = exception_payload("ActiveRecord::RecordNotFound",
      frame("active_record/core.rb", 253, "find", "ActiveRecord::Core::ClassMethods", app: false),
      frame("app/controllers/books_controller.rb", 10, "show", "BooksController"))
    old = old_issue("ActiveRecord::RecordNotFound::active_record/core.rb::253")

    event = assert_no_difference("Issue.count") { ingest(payload) }

    assert_equal old.id, event.issue_id
    assert_equal Issue.generate_fingerprint(payload), old.reload.fingerprint
  end

  test "a message issue grouped the 1.19.4 way takes the next event" do
    old = old_issue(Digest::MD5.hexdigest("Timeout after 3021ms for user 4412"))

    event = assert_no_difference("Issue.count") { ingest(message_payload("Timeout after 3021ms for user 4412")) }

    assert_equal old.id, event.issue_id
  end

  # 1.20.0 grouped by the raised exception (1.19.4 by the root cause), still
  # with the innermost frame's file and line.
  test "an exception issue grouped the 1.20.0 way takes the next event" do
    payload = exception_payload("PaymentFailed",
      frame("app/models/payment.rb", 42, "charge", "Payment"),
      frame("app/controllers/orders_controller.rb", 18, "create", "OrdersController"))
    payload["exception"]["values"].unshift({"type" => "Net::ReadTimeout", "value" => "Net::ReadTimeout",
      "stacktrace" => {"frames" => [frame("net/protocol.rb", 229, "rbuf_fill", app: false)]}})
    old = old_issue("PaymentFailed::app/models/payment.rb::42")

    event = assert_no_difference("Issue.count") { ingest(payload) }

    assert_equal old.id, event.issue_id
    assert_equal Issue.generate_fingerprint(payload), old.reload.fingerprint
  end

  # 1.19.4 put every event with no message it could read into one issue.
  test "the old catch-all Unknown Error issue isn't taken over" do
    catch_all = old_issue(Digest::MD5.hexdigest("Unknown Error"))

    event = ingest({"logentry" => {"message" => "Card %s declined", "params" => ["4412"]}, "timestamp" => "2026-10-11T08:00:00Z"})

    assert_not_equal catch_all.id, event.issue_id
  end

  private

  def ingest(payload)
    Event.create_from_sentry_payload!(SecureRandom.hex(16), payload, @project)
  end

  # A frame as sentry-ruby sends it. `app: false` is a gem's.
  def frame(filename, lineno, function, module_name = nil, app: true)
    {"filename" => filename, "lineno" => lineno, "function" => function, "module" => module_name, "in_app" => app}.compact
  end

  # Frames innermost first, as Ruby prints a backtrace; Sentry sends them the
  # other way round.
  def exception_payload(type, *frames, **extra)
    {
      "exception" => {"values" => [{"type" => type, "value" => "#{type} raised", "stacktrace" => {"frames" => frames.reverse}}]},
      "timestamp" => "2026-10-11T08:00:00Z",
      "platform" => "ruby"
    }.merge(extra.transform_keys(&:to_s))
  end

  def message_payload(message)
    {"message" => message, "timestamp" => "2026-10-11T08:00:00Z", "platform" => "ruby"}
  end

  def old_issue(fingerprint)
    Issue.create!(project: @project, fingerprint: fingerprint, title: "grouped by 1.19.4", first_seen: 1.day.ago, last_seen: 1.day.ago)
  end
end
