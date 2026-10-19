# frozen_string_literal: true

require "test_helper"

class TransactionKindTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    Facet.where(project_id: @project.id).delete_all
    Facet.reset_throttle!
  end

  # The ops the installed SDKs actually send: sentry-rails ≤ 6 names a job
  # queue.active_job and 7 queue.process, so jobs match on the prefix.
  test "classify reads the SDK's op" do
    assert_equal "web", TransactionKind.classify("http.server")
    assert_equal "job", TransactionKind.classify("queue.active_job")
    assert_equal "job", TransactionKind.classify("queue.process")
    assert_equal "job", TransactionKind.classify("queue.task.celery")
    assert_equal "other", TransactionKind.classify("websocket.server")
    assert_equal "other", TransactionKind.classify("pageload")
    assert_equal "other", TransactionKind.classify(nil)
  end

  test "harvest! stores job and other names, never web ones" do
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "CoverDownloadJob", op: "queue.process")
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "ApplicationCable::Connection#connect", op: "websocket.server")
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "ProductsController#show", op: "http.server")

    lookup = TransactionKind.lookup(@project.id)
    assert_equal %w[CoverDownloadJob], lookup.job_names
    assert_equal %w[ApplicationCable::Connection#connect], lookup.other_names
    assert_equal 2, Facet.where(project_id: @project.id, stream: TransactionKind::STREAM).count
  end

  test "an unlisted name is a web request" do
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "CoverDownloadJob", op: "queue.process")
    lookup = TransactionKind.lookup(@project.id)

    assert_equal "job", lookup.kind_of("CoverDownloadJob")
    assert_equal "web", lookup.kind_of("/application/.env")
  end

  test "a name seen as both a job and other is a job, so the kinds don't overlap" do
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "Odd", op: "queue.process")
    TransactionKind.harvest!(project_id: @project.id, transaction_name: "Odd", op: "custom")
    lookup = TransactionKind.lookup(@project.id)

    assert_equal "job", lookup.kind_of("Odd")
    assert_empty lookup.other_names
  end

  test "the lookup is per project" do
    other = Project.create!(name: "Other", slug: "other-kind", public_key: "other-kind-key")
    TransactionKind.harvest!(project_id: other.id, transaction_name: "CoverDownloadJob", op: "queue.process")

    assert_equal "web", TransactionKind.lookup(@project.id).kind_of("CoverDownloadJob")
    assert_equal "job", TransactionKind.lookup(other.id).kind_of("CoverDownloadJob")
  end

  test "clause matches nothing for a kind with no names, and everything for web with none listed" do
    lookup = TransactionKind.lookup(@project.id)

    assert_equal ["1 = 0", []], lookup.clause("job")
    assert_nil lookup.clause("web")
    assert_nil lookup.clause(nil)
  end

  test "normalize drops anything that isn't a kind" do
    assert_equal "job", TransactionKind.normalize("job")
    assert_nil TransactionKind.normalize("")
    assert_nil TransactionKind.normalize("jobs; DROP TABLE")
  end
end
