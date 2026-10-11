# frozen_string_literal: true

require "test_helper"

# The provider's discovery document, fetched from OIDC_ISSUER +
# /.well-known/openid-configuration, and checked before any of it is used.
#
# OIDC Discovery 1.0 §4.3: the "issuer" the document declares MUST be identical
# to the issuer it was fetched from, and if it isn't, the document MUST NOT be
# used. Splat used to build the client anyway, so a wrong OIDC_ISSUER sent
# people off to log in and only failed when the id_token's iss came back —
# after the round trip, as "Could not verify the identity token".
class OidcDiscoveryTest < ActionDispatch::IntegrationTest
  test "starting a login sends the browser to the provider's authorization endpoint" do
    with_provider(issuer: "https://idp.example.com/", declares: "https://idp.example.com/") do
      get "/login/start"

      assert_response :redirect
      assert_match %r{\Ahttps://idp\.example\.com/authorize\?}, response.location
    end
  end

  # The gem's discovery only speaks HTTPS; a provider on plain http in a dev or
  # internal setup worked only through the fallback that used to follow it.
  test "an http issuer's discovery document is fetched over http" do
    issuer = "http://localhost:9000/application/o/splat/"

    with_provider(issuer: issuer, declares: issuer) do |requested|
      get "/login/start"

      assert_equal ["http://localhost:9000/application/o/splat/.well-known/openid-configuration"], requested
      assert_match %r{\Ahttp://localhost:9000/authorize\?}, response.location
    end
  end

  test "a provider declaring a different issuer stops the login and names both" do
    with_provider(issuer: "https://idp.example.com", declares: "https://idp.example.com/") do
      get "/login/start"

      assert_redirected_to login_path
      assert_includes flash[:alert], %("https://idp.example.com")
      assert_includes flash[:alert], %("https://idp.example.com/")
    end
  end

  # The likeliest way to get here: the old OIDC_DISCOVERY_URL moved across
  # unchanged. Discovery still works, so the message has to say what to set.
  test "a discovery URL pasted into OIDC_ISSUER is caught before the login starts" do
    pasted = "https://idp.example.com/.well-known/openid-configuration"

    with_provider(issuer: pasted, declares: "https://idp.example.com") do
      get "/login/start"

      assert_redirected_to login_path
      assert_includes flash[:alert], %("https://idp.example.com")
    end
  end

  # Backchannel logout verifies its token against the JWKS the document points
  # at; a document that failed the issuer check mustn't supply it.
  test "a provider declaring a different issuer doesn't have its JWKS fetched" do
    controller = OidcAuthController.new
    fetched = []
    controller.define_singleton_method(:fetch_json) do |url, _purpose|
      fetched << url
      {"issuer" => "https://elsewhere.example.com", "jwks_uri" => "https://elsewhere.example.com/jwks"}
    end

    with_oidc_env("OIDC_ISSUER" => "https://idp.example.com") do
      error = assert_raises(RuntimeError) { controller.send(:fetch_jwks) }

      assert_includes error.message, %("https://elsewhere.example.com")
      assert_equal ["https://idp.example.com/.well-known/openid-configuration"], fetched
    end
  end

  private

  # Serve a discovery document at OIDC_ISSUER's well-known URL that declares
  # `declares` as its issuer, with endpoints on the same origin. Yields the URLs
  # Splat actually requested.
  def with_provider(issuer:, declares:)
    origin = URI.parse(issuer).then { |uri| "#{uri.scheme}://#{uri.host}:#{uri.port}" }
    document = {
      "issuer" => declares,
      "authorization_endpoint" => "#{origin}/authorize",
      "token_endpoint" => "#{origin}/token",
      "userinfo_endpoint" => "#{origin}/userinfo",
      "jwks_uri" => "#{origin}/jwks"
    }.to_json
    response = http_ok(document)
    requested = []

    # Built outside the lambda: with_stub installs it with define_method, so
    # inside it self is Net::HTTP.
    fetch = ->(uri, *) do
      requested << uri.to_s
      response
    end

    with_oidc_env("OIDC_ISSUER" => issuer) do
      with_stub(Net::HTTP, :get_response, fetch) { yield requested }
    end
  end

  def http_ok(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
    end
  end

  # Exactly these OIDC variables, never a developer's .env.
  def with_oidc_env(overrides)
    vars = {"OIDC_CLIENT_ID" => "splat-test", "OIDC_CLIENT_SECRET" => "s3cret"}.merge(overrides)
    original = SplatAuthorization::OIDC_VARS.index_with { |var| ENV[var] }
    vars.each { |var, value| ENV[var] = value }

    yield
  ensure
    original.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
  end
end
