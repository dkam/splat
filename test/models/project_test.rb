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

  SHA = "e59f6680a82f15d8f82131f9c4c417223f31a153"
  GITEA = "https://git.example/booko/booko/src/commit/{sha}/{path}#L{line}"
  APP_FRAME = {"filename" => "app/views/subscribes/show.html.erb", "lineno" => 5, "in_app" => true}.freeze

  test "source_url fills the template from the frame and the release's commit" do
    @project.source_url_template = GITEA

    assert_equal "https://git.example/booko/booko/src/commit/#{SHA}/app/views/subscribes/show.html.erb#L5",
      @project.source_url(APP_FRAME, release: "19.11.0+#{SHA}")
  end

  test "source_url leaves library frames unlinked: their paths aren't in the repository" do
    @project.source_url_template = GITEA
    frame = {"filename" => "action_view/base.rb", "lineno" => 281, "in_app" => false}

    assert_nil @project.source_url(frame, release: "19.11.0+#{SHA}")
  end

  test "source_url is nil when the template wants a commit the release doesn't name" do
    @project.source_url_template = GITEA

    assert_nil @project.source_url(APP_FRAME, release: "1.21.1")
  end

  test "source_url without {sha} links whatever ref the template names" do
    @project.source_url_template = "https://github.com/org/app/blob/main/{path}#L{line}"

    assert_equal "https://github.com/org/app/blob/main/app/views/subscribes/show.html.erb#L5",
      @project.source_url(APP_FRAME, release: nil)
  end

  test "source_url is nil for a frame with no repository-relative path or no line" do
    @project.source_url_template = GITEA
    release = "19.11.0+#{SHA}"

    assert_nil @project.source_url(APP_FRAME.merge("filename" => "/rails/app/models/book.rb"), release: release)
    assert_nil @project.source_url(APP_FRAME.merge("filename" => "https://booko.info/assets/app.js"), release: release)
    assert_nil @project.source_url(APP_FRAME.except("lineno"), release: release)
  end

  test "source_url escapes the path but keeps its slashes" do
    @project.source_url_template = GITEA

    assert_equal "https://git.example/booko/booko/src/commit/#{SHA}/app/my%20file.rb#L5",
      @project.source_url(APP_FRAME.merge("filename" => "app/my file.rb"), release: SHA)
  end

  test "source_url is nil without a template" do
    assert_nil @project.source_url(APP_FRAME, release: SHA)
  end

  test "source_url_template must be an http(s) URL with a {path} in it" do
    @project.source_url_template = "https://git.example/booko/booko/src/commit/{sha}/"
    refute @project.valid?
    assert @project.errors[:source_url_template].any?

    @project.source_url_template = "javascript:alert(1)//{path}"
    refute @project.valid?

    @project.source_url_template = GITEA
    assert @project.valid?
  end

  test "a blank source_url_template is stored as nil" do
    @project.update!(source_url_template: "  ")

    assert_nil @project.reload.source_url_template
  end
end
