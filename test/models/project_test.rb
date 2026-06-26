# frozen_string_literal: true

require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  test "forwarding? reflects presence of forward_dsns" do
    @project.forward_dsns = []
    refute @project.forwarding?

    @project.forward_dsns = ["https://k@a.example/1"]
    assert @project.forwarding?
  end

  test "forward_dsns_text splits, trims, drops blanks, and dedups" do
    @project.forward_dsns_text = "  https://k@a.example/1 \n\nhttps://k@b.example/2\nhttps://k@a.example/1\n"

    assert_equal ["https://k@a.example/1", "https://k@b.example/2"], @project.forward_dsns
  end

  test "forward_dsns_text getter joins the array with newlines" do
    @project.forward_dsns = ["https://k@a.example/1", "https://k@b.example/2"]

    assert_equal "https://k@a.example/1\nhttps://k@b.example/2", @project.forward_dsns_text
  end

  test "valid with parseable forward DSNs" do
    @project.forward_dsns = ["https://k@a.example/1", "http://k@b.example:8080/2"]

    assert @project.valid?
  end

  test "invalid when a forward DSN cannot be parsed" do
    @project.forward_dsns = ["https://k@a.example/1", "ftp://nope/2"]

    refute @project.valid?
    assert @project.errors[:forward_dsns].any? { |m| m.include?("ftp://nope/2") }
  end
end
