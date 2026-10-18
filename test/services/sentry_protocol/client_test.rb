require "test_helper"

class SentryProtocol::ClientTest < ActiveSupport::TestCase
  Client = SentryProtocol::Client

  CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

  test "ip prefers the SDK's user.ip_address, then the forwarding headers, then REMOTE_ADDR" do
    request = {"headers" => {"X-Forwarded-For" => "198.51.100.7, 10.0.0.2"}, "env" => {"REMOTE_ADDR" => "10.0.0.2"}}

    assert_equal "203.0.113.9", Client.ip({"user" => {"ip_address" => "203.0.113.9"}, "request" => request})
    assert_equal "198.51.100.7", Client.ip({"request" => request})
    assert_equal "10.0.0.2", Client.ip({"request" => {"env" => {"REMOTE_ADDR" => "10.0.0.2"}}})
  end

  # sentry-ruby 7 without send_default_pii keeps the headers and filters their
  # values; browser SDKs send {{auto}} for the server to fill in.
  test "ip skips values the SDK filtered or left for the server to fill in" do
    payload = {
      "user" => {"ip_address" => "{{auto}}"},
      "request" => {"headers" => {"X-Real-Ip" => "[Filtered]", "X-Forwarded-For" => "[Filtered]"}, "env" => {"REMOTE_ADDR" => "[Filtered]"}}
    }

    assert_nil Client.ip(payload)
    assert_nil Client.ip({})
  end

  test "headers are read whichever case and shape the SDK sent them in" do
    assert_equal "198.51.100.7", Client.ip({"request" => {"headers" => [["x-real-ip", "198.51.100.7"]]}})
    assert_equal CHROME_MAC, Client.user_agent({"request" => {"headers" => {"user-agent" => CHROME_MAC}}})
  end

  test "network is the /24 an IPv4 address is in, or the /48 for IPv6" do
    assert_equal "198.51.100.0/24", Client.network("198.51.100.7")
    assert_equal "2001:db8:abcd::/48", Client.network("2001:db8:abcd:12::1")
    assert_nil Client.network(nil)
    assert_nil Client.network("not an address")
  end

  test "user names the user by id, username or email, but not by IP address" do
    assert_equal "id:7", Client.user({"user" => {"id" => 7, "email" => "a@example.com"}})
    assert_equal "email:a@example.com", Client.user({"user" => {"email" => "a@example.com"}})
    assert_nil Client.user({"user" => {"ip_address" => "203.0.113.9"}})
    assert_nil Client.user({"user" => {}})
  end

  test "browser and os come from the User-Agent" do
    {
      CHROME_MAC => ["Chrome 145", "macOS"],
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0" => ["Edge 141", "Windows"],
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1" => ["Safari 18", "iOS"],
      "Mozilla/5.0 (X11; Linux x86_64; rv:139.0) Gecko/20100101 Firefox/139.0" => ["Firefox 139", "Linux"],
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36" => ["Chrome 140", "Android"],
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" => ["Googlebot", nil],
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)" => ["ClaudeBot", nil],
      "curl/8.7.1" => ["curl", nil]
    }.each do |ua, (browser, os)|
      assert_equal [browser, os], [Client.browser(ua), Client.os(ua)], ua
    end

    assert_nil Client.browser(nil)
  end
end
