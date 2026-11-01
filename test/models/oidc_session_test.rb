require "test_helper"

class OidcSessionTest < ActiveSupport::TestCase
  # Clinch keeps one sid for as long as you're signed in there, so logging in
  # again after a mapping expires (24 hours) or a backchannel logout
  # invalidates it presents the same sid. The old row stays until the hourly
  # cleanup, and a second row beside it failed uniqueness: the login went
  # through untracked, the next page found no live mapping and logged you out,
  # round and round until the cleanup ran.
  test "logging in again takes over the sid's expired mapping" do
    OidcSession.create!(oidc_sid: "sid-1", session_id: "old", user_email: "a@example.com", expires_at: 1.minute.ago)

    OidcSession.create_for_user(oidc_sid: "sid-1", session_id: "new", user_email: "a@example.com")

    mapping = OidcSession.find_by_oidc_sid("sid-1")
    assert mapping, "no live mapping for the sid after logging in"
    assert_equal "new", mapping.session_id
    assert_equal 1, OidcSession.where(oidc_sid: "sid-1").count
  end
end
