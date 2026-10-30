# frozen_string_literal: true

require "test_helper"

class CompressionDictionarySeederTest < ActiveSupport::TestCase
  # Huxley's review: with a legacy logs database there and its import failing,
  # the seeder went on to seed logs v1, which takes an id the legacy rows may
  # point at, and an active slot the legacy dictionary needs.
  test "doesn't seed a logs dictionary over a legacy database it couldn't import" do
    Dir.mktmpdir("legacy") do |dir|
      Logs::DayFiles.legacy_path = build_legacy_logs(Pathname(dir).join("logs.sqlite3"))

      with_stub(Logs::Catalog, :import_legacy!, -> { raise SQLite3::BusyException, "database is locked" }) do
        _, err = capture_io { load Rails.root.join("db/seeds/compression_dictionaries.rb") }
        assert_match(/not imported/, err)
      end

      refute Compression::LogsDict.exists?(segment: "logs")
      assert Compression::IssuesEventsDict.exists?(segment: "events"), "the events dictionary is unaffected"
    ensure
      Logs::DayFiles.legacy_path = nil
    end
  end
end
