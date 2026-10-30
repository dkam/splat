# frozen_string_literal: true

require "test_helper"

# The import reads the legacy file over its own connection, so these can keep
# their test transaction: what's written goes to the catalog.
class Logs::CatalogTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir("legacy"))
    Compression::DictStore.reset!
  end

  teardown do
    Logs::DayFiles.legacy_path = nil
    Compression::DictStore.reset!
    FileUtils.rm_rf(@dir)
  end

  def dict_bytes(tag) = Array.new(20) { |i| %({"body":"#{tag} line #{i}","attributes":{"sentry.environment":"production"}}) }.join

  def legacy_with(dictionaries)
    Logs::DayFiles.legacy_path = build_legacy_logs(@dir.join("logs.sqlite3"), dictionaries: dictionaries)
  end

  test "copies the legacy dictionaries under their own ids" do
    legacy_with([{id: 14, segment: "logs", version: 3, dict: dict_bytes("a"), active: true},
      {id: 9, segment: "logs:platform:otlp", version: 1, dict: dict_bytes("b"), active: false}])

    assert_equal 2, Logs::Catalog.import_legacy!

    assert_equal [[9, "logs:platform:otlp", 1, false], [14, "logs", 3, true]],
      Compression::LogsDict.order(:id).pluck(:id, :segment, :version, :active)
    assert_equal dict_bytes("a").b, Compression::LogsDict.find(14).dict
    assert_equal 14, Compression::DictStore.active_id(:logs, "logs")
  end

  # What the import is for: rows written before the cutover name their
  # dictionary by its legacy id.
  test "a payload compressed with a legacy dictionary decodes after the import" do
    legacy_with([{id: 14, segment: "logs", version: 3, dict: dict_bytes("a"), active: true}])
    blob = Zstd.compress(%({"body":"a line 99"}), level: Compression::Codec::LEVEL, dict: dict_bytes("a"))

    Logs::Catalog.import_legacy!

    assert_equal({"body" => "a line 99"}, Compression::Codec.decode_json(blob, db: :logs, dict_id: 14))
  end

  test "runs again without copying anything twice" do
    legacy_with([{id: 14, segment: "logs", version: 3, dict: dict_bytes("a"), active: true}])
    Logs::Catalog.import_legacy!

    assert_equal 0, Logs::Catalog.import_legacy!
    assert_equal 1, Compression::LogsDict.count
  end

  test "reports a legacy id the catalog already uses for another dictionary, and leaves it" do
    Compression::LogsDict.create!(id: 14, segment: "logs", version: 1, dict: dict_bytes("seeded"), trained_at: Time.current, active: true)
    legacy_with([{id: 14, segment: "logs", version: 3, dict: dict_bytes("a"), active: false}])
    logged = []

    with_stub(Rails.logger, :error, ->(msg) { logged << msg }) { Logs::Catalog.import_legacy! }

    assert_equal ["logs", 1], Compression::LogsDict.find(14).then { [it.segment, it.version] }
    assert_match(/legacy dictionary 14 \(logs v3\) not copied/, logged.join)
  end

  test "nothing to do with a legacy file that has no dictionaries in it" do
    stub = @dir.join("logs.sqlite3")
    SQLite3::Database.new(stub.to_s).close
    Logs::DayFiles.legacy_path = stub

    assert_equal 0, Logs::Catalog.import_legacy!
  end

  test "nothing to do without a legacy database" do
    assert_equal 0, Logs::Catalog.import_legacy!
  end
end
