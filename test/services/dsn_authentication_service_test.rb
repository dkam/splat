# frozen_string_literal: true

require "test_helper"

class DsnAuthenticationServiceTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Test Project", slug: "test-project", public_key: "test-public-key-123")
  end

  test "authenticates with query parameter sentry_key" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = @project.public_key

    authenticated_project = DsnAuthenticationService.authenticate(request, @project.slug)

    assert_equal @project, authenticated_project
  end

  test "authenticates with query parameter glitchtip_key" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:glitchtip_key] = @project.public_key

    authenticated_project = DsnAuthenticationService.authenticate(request, @project.id)

    assert_equal @project, authenticated_project
  end

  test "authenticates with X-Sentry-Auth header" do
    request = ActionDispatch::TestRequest.create
    request.headers["X-Sentry-Auth"] = "Sentry sentry_key=#{@project.public_key}, sentry_version=7, sentry_client=ruby-sdk/1.0.0"

    authenticated_project = DsnAuthenticationService.authenticate(request, @project.slug)

    assert_equal @project, authenticated_project
  end

  test "authenticates with Bearer Authorization header" do
    request = ActionDispatch::TestRequest.create
    request.headers["Authorization"] = "Bearer #{@project.public_key}"

    authenticated_project = DsnAuthenticationService.authenticate(request, @project.id)

    assert_equal @project, authenticated_project
  end

  test "fails authentication with wrong public key" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "wrong-key"

    assert_raises(DsnAuthenticationService::AuthenticationError) do
      DsnAuthenticationService.authenticate(request, @project.slug)
    end
  end

  test "fails authentication with wrong project ID" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = @project.public_key

    assert_raises(DsnAuthenticationService::AuthenticationError) do
      DsnAuthenticationService.authenticate(request, "nonexistent-project")
    end
  end

  test "fails authentication with no credentials" do
    request = ActionDispatch::TestRequest.create

    assert_raises(DsnAuthenticationService::AuthenticationError) do
      DsnAuthenticationService.authenticate(request, @project.slug)
    end
  end

  test "extracts public key from Sentry header with multiple params" do
    header = "Sentry sentry_key=#{@project.public_key}, sentry_version=7, sentry_client=ruby-sdk/1.0.0, sentry_timestamp=1234567890"
    request = ActionDispatch::TestRequest.create
    request.headers["X-Sentry-Auth"] = header
    extracted_key = DsnAuthenticationService.extract_public_key(request)

    assert_equal @project.public_key, extracted_key
  end

  test "returns nil for malformed Sentry header" do
    header = "Invalid header format"
    extracted_key = DsnAuthenticationService.send(:parse_sentry_auth_header, header)

    assert_nil extracted_key
  end

  # --- Trusted-forwarder mode -------------------------------------------------

  test "trusted forwarder header without server token does nothing" do
    request = make_request(sentry_key: "any-key", forwarder_token: "anything")

    with_env("SPLAT_FORWARDER_TOKEN" => nil) do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "brand-new-app")
      end
    end
    assert_nil Project.find_by(slug: "brand-new-app")
  end

  test "mismatched forwarder token falls through to direct DSN auth" do
    request = make_request(sentry_key: "wrong-key", forwarder_token: "wrong-token")

    with_env("SPLAT_FORWARDER_TOKEN" => "correct-token") do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, @project.slug)
      end
    end
  end

  test "trusted forwarder returns existing project even when public_key mismatches stored key" do
    # This is the whole point of Model 3: cross-instance key drift becomes a non-issue
    # for forwarded envelopes — only the forwarder token matters.
    request = make_request(sentry_key: "totally-different-key", forwarder_token: "T")

    project = with_env("SPLAT_FORWARDER_TOKEN" => "T") do
      DsnAuthenticationService.authenticate(request, @project.slug)
    end

    assert_equal @project, project
    assert_equal "test-public-key-123", project.reload.public_key  # stored key unchanged
  end

  test "trusted forwarder auto-creates unknown slug using inbound public_key" do
    request = make_request(sentry_key: "baffle-key-abc", forwarder_token: "T")

    project = with_env("SPLAT_FORWARDER_TOKEN" => "T") do
      DsnAuthenticationService.authenticate(request, "baffle")
    end

    assert_equal "baffle", project.slug
    assert_equal "baffle-key-abc", project.public_key
    assert_equal "Baffle", project.name
  end

  test "trusted forwarder rejects malformed slug for auto-create" do
    request = make_request(sentry_key: "any-key", forwarder_token: "T")

    with_env("SPLAT_FORWARDER_TOKEN" => "T") do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "Has Spaces")
      end
    end
    assert_nil Project.find_by(slug: "Has Spaces")
  end

  test "trusted forwarder rejects numeric project id" do
    # Numeric ids hit find_by_project_id's id-based fallback first; if nothing
    # exists, auto-create's leading-letter regex rejects them.
    request = make_request(sentry_key: "any-key", forwarder_token: "T")

    with_env("SPLAT_FORWARDER_TOKEN" => "T") do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "9999")
      end
    end
  end

  test "forwarder token comparison rejects shorter-prefix tokens" do
    # secure_compare returns false on length mismatch — no early-exit timing leak.
    request = make_request(sentry_key: "any-key", forwarder_token: "T")

    with_env("SPLAT_FORWARDER_TOKEN" => "TT") do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "new-slug")
      end
    end
    assert_nil Project.find_by(slug: "new-slug")
  end

  private

  def make_request(sentry_key:, forwarder_token: nil)
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = sentry_key
    request.headers[DsnAuthenticationService::FORWARDER_TOKEN_HEADER] = forwarder_token if forwarder_token
    request
  end

  def with_env(vars)
    previous = vars.transform_values { |_| nil }
    vars.each { |k, _| previous[k] = ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end
end
