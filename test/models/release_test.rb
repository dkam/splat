# frozen_string_literal: true

require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  SHA = "e59f6680a82f15d8f82131f9c4c417223f31a153"

  test "commit_sha finds a full SHA in a version's build metadata" do
    assert_equal SHA, Release.commit_sha("19.11.0+#{SHA}")
  end

  test "commit_sha takes a release that is only a SHA" do
    assert_equal SHA, Release.commit_sha(SHA)
  end

  test "commit_sha is nil for a release that names no commit" do
    assert_nil Release.commit_sha("1.21.1")
    assert_nil Release.commit_sha("1.0.0+20261014")
    assert_nil Release.commit_sha("")
    assert_nil Release.commit_sha(nil)
  end

  test "commit_sha doesn't take 40 characters of a longer hex run for a SHA" do
    assert_nil Release.commit_sha("1.0.0+#{SHA}#{SHA}")
  end
end
