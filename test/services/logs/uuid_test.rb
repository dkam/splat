require "test_helper"

class Logs::UuidTest < ActiveSupport::TestCase
  UUID = "550e8400-e29b-41d4-a716-446655440000"
  FLAT = "550e8400e29b41d4a716446655440000"

  test "collapses a standalone canonical UUID" do
    assert_equal FLAT, Logs::Uuid.collapse(UUID)
  end

  test "collapses a UUID embedded in a path, leaving the rest intact" do
    assert_equal "/api/v3/imports/#{FLAT}/edit", Logs::Uuid.collapse("/api/v3/imports/#{UUID}/edit")
  end

  test "is case-insensitive" do
    assert_equal FLAT, Logs::Uuid.collapse(UUID.upcase).downcase
  end

  test "leaves non-UUID hyphenated strings alone" do
    assert_equal "1.4.0-dev", Logs::Uuid.collapse("1.4.0-dev")
    assert_equal "trace-id-foo", Logs::Uuid.collapse("trace-id-foo")
    # ULIDs are already hyphen-free — untouched
    assert_equal "01ARZ3NDEKTSV4RRFFQ69G5FAV", Logs::Uuid.collapse("01ARZ3NDEKTSV4RRFFQ69G5FAV")
  end

  test "tolerates nil" do
    assert_nil Logs::Uuid.collapse(nil)
  end
end
