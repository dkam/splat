# frozen_string_literal: true

require "test_helper"

class Logs::OtlpChunkerTest < ActiveSupport::TestCase
  def payload_with(records, resource_attrs: [{"key" => "service.name", "value" => {"stringValue" => "postgres"}}])
    {
      "resourceLogs" => [
        {
          "resource" => {"attributes" => resource_attrs},
          "scopeLogs" => [{"scope" => {"name" => "pg.scraper"}, "logRecords" => records}]
        }
      ]
    }
  end

  def record(body)
    {"severityNumber" => 9, "body" => {"stringValue" => body}}
  end

  def all_bodies(chunks)
    chunks.flat_map do |chunk|
      chunk["resourceLogs"].flat_map do |rl|
        rl["scopeLogs"].flat_map { |sl| sl["logRecords"].map { |r| r.dig("body", "stringValue") } }
      end
    end
  end

  test "payload under the limit passes through untouched as a single chunk" do
    payload = payload_with([record("hi")])
    assert_equal [payload], Logs::OtlpChunker.chunks(payload)
  end

  test "oversized payload splits into chunks that each fit, preserving records and envelope" do
    records = 10.times.map { |i| record("record-#{i}-" + "x" * 200) }
    payload = payload_with(records)

    chunks = Logs::OtlpChunker.chunks(payload, max_bytes: 600)

    assert_operator chunks.size, :>, 1
    chunks.each do |chunk|
      assert_operator JSON.generate(chunk).bytesize, :<=, 600
      # resource/scope envelope survives so the parser sees a normal payload
      assert_equal "postgres", chunk["resourceLogs"][0]["resource"]["attributes"][0].dig("value", "stringValue")
      assert_equal "pg.scraper", chunk["resourceLogs"][0]["scopeLogs"][0]["scope"]["name"]
    end
    assert_equal records.map { |r| r.dig("body", "stringValue") }, all_bodies(chunks)
  end

  test "a single record over the limit is emitted as its own chunk" do
    records = [record("small"), record("huge-" + "x" * 2000), record("small2")]
    payload = payload_with(records)

    chunks = Logs::OtlpChunker.chunks(payload, max_bytes: 600)

    assert_equal ["small", records[1].dig("body", "stringValue"), "small2"], all_bodies(chunks)
    oversized = chunks.select { |c| JSON.generate(c).bytesize > 600 }
    assert_equal 1, oversized.size, "only the huge record's chunk exceeds the limit"
    assert_equal 1, Logs::OtlpChunker.record_count(oversized.first)
  end

  test "splits across multiple resourceLogs and scopeLogs" do
    payload = {
      "resourceLogs" => [
        {"resource" => {"attributes" => []},
         "scopeLogs" => [
           {"scope" => {"name" => "a"}, "logRecords" => 5.times.map { |i| record("a-#{i}-" + "x" * 200) }},
           {"scope" => {"name" => "b"}, "logRecords" => [record("b-0")]}
         ]},
        {"resource" => {"attributes" => []},
         "scopeLogs" => [{"scope" => {"name" => "c"}, "logRecords" => [record("c-0")]}]}
      ]
    }

    chunks = Logs::OtlpChunker.chunks(payload, max_bytes: 500)

    assert_equal 7, chunks.sum { |c| Logs::OtlpChunker.record_count(c) }
    assert_includes all_bodies(chunks), "b-0"
    assert_includes all_bodies(chunks), "c-0"
  end

  test "record_count sums logRecords across the whole payload" do
    assert_equal 1, Logs::OtlpChunker.record_count(payload_with([record("x")]))
    assert_equal 0, Logs::OtlpChunker.record_count({})
  end
end
