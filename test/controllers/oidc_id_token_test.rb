# frozen_string_literal: true

require "test_helper"

# ID token verification on the callback path.
#
# This used to be JWT.decode(id_token, nil, false) — permitted by OIDC Core
# 3.1.3.7 for the code flow, since the token arrives over a direct TLS
# connection to the token endpoint rather than through the browser. The JWKS was
# already being fetched for backchannel logout, so these checks cost one call
# and mean nobody has to re-derive whether that exception still applies.
class OidcIdTokenTest < ActiveSupport::TestCase
  SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)
  SIGNING_JWK = JWT::JWK.new(SIGNING_KEY)
  JWKS = JWT::JWK::Set.new([SIGNING_JWK.export])

  OTHER_KEY = OpenSSL::PKey::RSA.generate(2048)
  OTHER_JWK = JWT::JWK.new(OTHER_KEY)

  ISSUER = "https://idp.example.com/application/o/splat/"
  CLIENT_ID = "splat-test-client"

  test "accepts a correctly signed token and returns its claims" do
    claims = claims_from(signed_token)

    assert_equal "dev@example.com", claims[:email]
    assert_equal "Dev Person", claims[:name]
    assert_equal "sid-123", claims[:sid]
  end

  test "rejects a token signed by a key that isn't the provider's" do
    forged = JWT.encode(default_payload, OTHER_KEY, "RS256", {kid: OTHER_JWK.kid})

    assert_raises(JWT::DecodeError) { claims_from(forged) }
  end

  test "rejects an unsigned token" do
    unsigned = JWT.encode(default_payload, nil, "none")

    assert_raises(JWT::DecodeError) { claims_from(unsigned) }
  end

  test "rejects a token from the wrong issuer" do
    assert_raises(JWT::InvalidIssuerError) do
      claims_from(signed_token(iss: "https://evil.example.com/"))
    end
  end

  test "rejects a token issued to a different client" do
    assert_raises(JWT::InvalidAudError) do
      claims_from(signed_token(aud: "some-other-app"))
    end
  end

  test "rejects an expired token" do
    assert_raises(JWT::ExpiredSignature) do
      claims_from(signed_token(exp: 5.minutes.ago.to_i))
    end
  end

  test "accepts an audience array that includes this client" do
    claims = claims_from(signed_token(aud: ["some-other-app", CLIENT_ID]))

    assert_equal "dev@example.com", claims[:email]
  end

  # ---- issuer resolution ------------------------------------------------

  # Providers whose issuer is path-suffixed (Authentik, Keycloak realms) don't
  # round-trip through "strip .well-known from the discovery URL" reliably, and
  # verify_iss would reject a perfectly good provider.
  test "expected_issuer prefers what the provider declares" do
    controller = OidcAuthController.new
    controller.define_singleton_method(:discovery_document) { {"issuer" => ISSUER} }

    with_env("OIDC_DISCOVERY_URL" => "https://idp.example.com/other/.well-known/openid-configuration") do
      assert_equal ISSUER, controller.send(:expected_issuer)
    end
  end

  test "expected_issuer honours OIDC_ISSUER above discovery" do
    controller = OidcAuthController.new
    controller.define_singleton_method(:discovery_document) { {"issuer" => ISSUER} }

    with_env("OIDC_ISSUER" => "https://explicit.example.com/") do
      assert_equal "https://explicit.example.com/", controller.send(:expected_issuer)
    end
  end

  test "expected_issuer falls back to the discovery URL when discovery fails" do
    controller = OidcAuthController.new
    controller.define_singleton_method(:discovery_document) { raise SocketError, "no route" }

    with_env("OIDC_DISCOVERY_URL" => "https://idp.example.com/o/splat/.well-known/openid-configuration") do
      assert_equal "https://idp.example.com/o/splat", controller.send(:expected_issuer)
    end
  end

  # ---- discovery URL normalisation --------------------------------------

  # OIDC_DISCOVERY_URL is documented as the issuer base in README.md and as the
  # full well-known URL in .env.example, so both reach real deployments. Fetching
  # the base lands on the provider's home page — a 302 with an empty body, which
  # used to surface as "Failed to fetch JWKS: unexpected end of input".
  test "discovery_url appends the well-known path to an issuer base" do
    assert_discovery_url "https://idp.example.com/.well-known/openid-configuration",
      from: "https://idp.example.com"
  end

  test "discovery_url leaves a full well-known URL alone" do
    assert_discovery_url "https://idp.example.com/.well-known/openid-configuration",
      from: "https://idp.example.com/.well-known/openid-configuration"
  end

  test "discovery_url keeps the path of a realm-scoped provider" do
    assert_discovery_url "https://idp.example.com/realms/splat/.well-known/openid-configuration",
      from: "https://idp.example.com/realms/splat"
  end

  test "discovery_url tolerates a trailing slash" do
    assert_discovery_url "https://idp.example.com/.well-known/openid-configuration",
      from: "https://idp.example.com/"
  end

  # Splat's own README recommended the underscore spelling for Google, Okta,
  # Auth0 and Microsoft. It 404s at every one of them.
  test "discovery_url corrects the underscore spelling" do
    assert_discovery_url "https://idp.example.com/.well-known/openid-configuration",
      from: "https://idp.example.com/.well-known/openid_configuration"
  end

  test "extract_issuer_from_discovery strips the well-known suffix" do
    controller = OidcAuthController.new

    with_env("OIDC_DISCOVERY_URL" => "https://idp.example.com/.well-known/openid-configuration") do
      assert_equal "https://idp.example.com", controller.send(:extract_issuer_from_discovery)
    end
  end

  private

  def assert_discovery_url(expected, from:)
    controller = OidcAuthController.new

    with_env("OIDC_DISCOVERY_URL" => from) do
      assert_equal expected, controller.send(:discovery_url)
    end
  end

  def default_payload
    {
      "iss" => ISSUER,
      "aud" => CLIENT_ID,
      "sub" => "user-1",
      "exp" => 5.minutes.from_now.to_i,
      "iat" => Time.current.to_i,
      "email" => "dev@example.com",
      "name" => "Dev Person",
      "sid" => "sid-123"
    }
  end

  def signed_token(**overrides)
    payload = default_payload.merge(overrides.transform_keys(&:to_s))
    JWT.encode(payload, SIGNING_KEY, "RS256", {kid: SIGNING_JWK.kid})
  end

  # Exercise the real verification options with the two things that would
  # otherwise reach out over the network stubbed out.
  def claims_from(token)
    controller = OidcAuthController.new
    controller.define_singleton_method(:fetch_jwks) { JWKS }
    controller.define_singleton_method(:expected_issuer) { ISSUER }

    with_env("OIDC_CLIENT_ID" => CLIENT_ID) do
      controller.send(:extract_claims_from_id_token, token)
    end
  end

  def with_env(vars)
    original = vars.keys.index_with { |var| ENV[var] }
    vars.each { |var, value| ENV[var] = value }
    yield
  ensure
    original.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
  end
end
