# frozen_string_literal: true

require "test_helper"
require "ostruct"

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
    request.headers['X-Sentry-Auth'] = "Sentry sentry_key=#{@project.public_key}, sentry_version=7, sentry_client=ruby-sdk/1.0.0"

    authenticated_project = DsnAuthenticationService.authenticate(request, @project.slug)

    assert_equal @project, authenticated_project
  end

  test "authenticates with Bearer Authorization header" do
    request = ActionDispatch::TestRequest.create
    request.headers['Authorization'] = "Bearer #{@project.public_key}"

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
    extracted_key = DsnAuthenticationService.extract_public_key(
      OpenStruct.new(headers: { 'X-Sentry-Auth' => header }, GET: {})
    )

    assert_equal @project.public_key, extracted_key
  end

  test "returns nil for malformed Sentry header" do
    header = "Invalid header format"
    extracted_key = DsnAuthenticationService.parse_sentry_auth_header(header)

    assert_nil extracted_key
  end

  test "auto-create disabled when SPLAT_AUTO_CREATE_SLUGS unset" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "fresh-key"

    with_env('SPLAT_AUTO_CREATE_SLUGS' => nil) do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "brand-new-app")
      end
    end
    assert_nil Project.find_by(slug: "brand-new-app")
  end

  test "auto-create disabled when SPLAT_AUTO_CREATE_SLUGS is empty" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "fresh-key"

    with_env('SPLAT_AUTO_CREATE_SLUGS' => '') do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "brand-new-app")
      end
    end
    assert_nil Project.find_by(slug: "brand-new-app")
  end

  test "auto-creates project when slug is in SPLAT_AUTO_CREATE_SLUGS list" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "baffle-key-abc"

    project = with_env('SPLAT_AUTO_CREATE_SLUGS' => 'baffle,other') do
      DsnAuthenticationService.authenticate(request, "baffle")
    end

    assert_equal "baffle", project.slug
    assert_equal "baffle-key-abc", project.public_key
  end

  test "auto-creates project when SPLAT_AUTO_CREATE_SLUGS is wildcard" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "anything-key"

    project = with_env('SPLAT_AUTO_CREATE_SLUGS' => '*') do
      DsnAuthenticationService.authenticate(request, "some-new-app")
    end

    assert_equal "some-new-app", project.slug
    assert_equal "anything-key", project.public_key
  end

  test "auto-create rejects slug not in allowlist" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "fresh-key"

    with_env('SPLAT_AUTO_CREATE_SLUGS' => 'baffle') do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "not-allowed")
      end
    end
    assert_nil Project.find_by(slug: "not-allowed")
  end

  test "auto-create rejects malformed slug even with wildcard" do
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "fresh-key"

    with_env('SPLAT_AUTO_CREATE_SLUGS' => '*') do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "Has Spaces")
      end
    end
    assert_nil Project.find_by(slug: "Has Spaces")
  end

  test "auto-create rejects numeric project id even with wildcard" do
    # Numeric IDs hit find_by_project_id's id-based fallback, never auto-create.
    request = ActionDispatch::TestRequest.create
    request.query_parameters[:sentry_key] = "fresh-key"

    with_env('SPLAT_AUTO_CREATE_SLUGS' => '*') do
      assert_raises(DsnAuthenticationService::AuthenticationError) do
        DsnAuthenticationService.authenticate(request, "9999")
      end
    end
  end

  private

  def with_env(vars)
    previous = vars.transform_values { |_| nil }
    vars.each { |k, _| previous[k] = ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end
end