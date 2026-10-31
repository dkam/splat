# frozen_string_literal: true

require "test_helper"

class Logs::WriterTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  def row(log_id:, body:, attrs_text: nil, at: Time.current)
    {project_id: @project.id, log_id: log_id, timestamp: at, level: Log.levels["info"], body: body,
     attrs_text: attrs_text, source: "sentry", created_at: at}
  end

  # A batch built either side of midnight: each row goes to the day its
  # log_id was minted, so a log_id always names its file.
  test "a batch that straddles midnight splits between the two days' files" do
    midnight = Time.now.utc.beginning_of_day
    before = log_id_at(midnight - 1)
    after = log_id_at(midnight + 1)

    Logs::Writer.insert!([row(log_id: before, body: "before midnight"), row(log_id: after, body: "after midnight")])

    assert_equal midnight.to_date - 1, Logs::DayFiles.shard_for_log_id(before).day
    assert_equal "before midnight", Logs::DayFiles.shard_for_log_id(before).with { Log.find_by(log_id: before).body }
    assert_equal "after midnight", Logs::DayFiles.shard_for_log_id(after).with { Log.find_by(log_id: after).body }
  end

  # attrs_text is indexed and not stored, and each index entry has to land on
  # its own row's rowid.
  test "each row is indexed under its own rowid, attributes included" do
    rows = Array.new(30) { |i| row(log_id: SecureRandom.uuid_v7, body: "line #{i}", attrs_text: "seq n#{i}") }

    Logs::Writer.insert!(rows)

    rows.each_with_index do |r, i|
      found = Logs::Reader.list(limit: 5) { Log.search_text("seq:n#{i}") }
      assert_equal [r[:log_id]], found.map(&:log_id), "seq:n#{i}"
    end
    refute Logs::DayFiles.write(Time.now.utc.to_date) { Log.column_names.include?("attrs_text") }
  end
end
