# frozen_string_literal: true

require "test_helper"

class Ingest::ForwardConsumerTest < ActiveSupport::TestCase
  # Minimal stand-in for a Beaneater job. process_batch only needs #body plus
  # the finalize verbs; we record which one was called.
  class FakeJob
    attr_reader :body, :finalized

    def initialize(body)
      @body = body
      @finalized = nil
    end

    def delete = @finalized = :delete
    def bury = @finalized = :bury
    def release(**) = @finalized = :release
  end

  setup do
    @project = projects(:one)
    @consumer = Ingest::ForwardConsumer.new
  end

  test "delivers to each DSN and deletes the job" do
    job = FakeJob.new(JSON.generate(
      project_id: @project.id,
      body: Base64.strict_encode64("raw-envelope"),
      content_type: "application/x-sentry-envelope",
      dsns: ["https://k@a.example/1", "https://k@b.example/2"]
    ))

    calls = capture_deliveries { @consumer.send(:process_batch, [job]) }

    assert_equal 2, calls.size
    assert_equal ["https://k@a.example/1", "https://k@b.example/2"], calls.map { |c| c[:dsn] }
    assert_equal "raw-envelope", calls.first[:raw_body]
    assert_equal @project.id, calls.first[:project].id
    assert_equal :delete, job.finalized
  end

  test "drops (deletes) a job for a missing project without delivering" do
    job = FakeJob.new(JSON.generate(
      project_id: 999_999,
      body: Base64.strict_encode64("raw"),
      dsns: ["https://k@a.example/1"]
    ))

    calls = capture_deliveries { @consumer.send(:process_batch, [job]) }

    assert_empty calls
    assert_equal :delete, job.finalized
  end

  test "deletes a malformed job rather than cycling it forever" do
    job = FakeJob.new("not json")

    capture_deliveries { @consumer.send(:process_batch, [job]) }

    assert_equal :delete, job.finalized
  end

  private

  # Override deliver, then *restore the saved original* in ensure. The old
  # define_method/remove_method version deleted deliver outright, leaving it
  # undefined for the rest of the worker process and intermittently breaking
  # EnvelopeForwarderTest. (Minitest 6 has no #stub.)
  def capture_deliveries
    calls = []
    original = EnvelopeForwarder.method(:deliver)
    EnvelopeForwarder.define_singleton_method(:deliver) do |raw_body, dsn:, project:, content_type: nil|
      calls << {raw_body: raw_body, dsn: dsn, project: project, content_type: content_type}
      true
    end
    begin
      yield
    ensure
      EnvelopeForwarder.define_singleton_method(:deliver, original)
    end
    calls
  end
end
