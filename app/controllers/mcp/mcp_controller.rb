# frozen_string_literal: true

module Mcp
  # The HTTP edge of Splat's MCP server: authenticate, hand the JSON-RPC frame to
  # the `mcp` gem, render what comes back.
  #
  # This used to be ~2500 lines that also spoke JSON-RPC by hand and pinned
  # protocol version 2024-11-05. The protocol half now lives in the gem
  # (SplatMcpServer builds the server, SplatMcpTools implements the tools), which
  # gets us version negotiation up to the current spec, `ping`, tool annotations,
  # and the rest without maintaining any of it here.
  #
  # Deliberately *not* using MCP::Server::Transports::StreamableHTTPTransport.
  # Splat has no use for SSE streaming or server-initiated messages, so the
  # transport would only add per-request session state and DNS-rebinding
  # Host/Origin allow-lists to configure — the latter a live 403 risk behind the
  # reverse proxy. `handle_json` is the whole protocol without either.
  class McpController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    before_action :authenticate_mcp_token

    # The gem turns tool exceptions into JSON-RPC errors itself, so this only
    # catches failures in the frame handling around it.
    rescue_from StandardError do |exception|
      Rails.logger.error("MCP Error: #{exception.message}\n#{exception.backtrace.join("\n")}")
      render json: {
        jsonrpc: "2.0",
        error: {code: -32603, message: "Internal server error", data: exception.message},
        id: @rpc_id
      }, status: 500
    end

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: {
        jsonrpc: "2.0",
        error: {code: -32700, message: "Parse error"},
        id: nil
      }, status: :bad_request
    end

    def handle_mcp_request
      request.body.rewind
      raw_body = request.body.read

      # A GET, or a client that put the frame in the query string rather than the
      # body. Tolerated because it always was.
      rpc_request = if raw_body.blank?
        params.as_json.except("controller", "action", "mcp")
      else
        JSON.parse(raw_body)
      end

      @rpc_id = rpc_request["id"]

      response_hash = SplatMcpServer.build.handle(rpc_request.deep_symbolize_keys)

      # nil is a notification — nothing to answer, and answering anyway is a
      # protocol violation.
      if response_hash.nil?
        head :accepted
      else
        render json: response_hash
      end
    end

    private

    def authenticate_mcp_token
      token = request.headers["Authorization"]&.remove(/^Bearer\s+/i)
      outcome = mcp_auth_outcome(token)
      return if outcome == :ok

      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32001,
          message: mcp_auth_error_message(outcome)
        },
        id: nil
      }, status: :unauthorized
    end

    # The :expired message is deliberately actionable — it's surfaced to the
    # human by the MCP client — and names the URL to renew at. Every other
    # failure stays generic: an unrecognised caller is told nothing specific.
    def mcp_auth_error_message(outcome)
      if outcome == :expired
        "MCP token expired — its owner hasn't signed in to Splat lately. " \
          "Sign in at #{Current.external_base_url}/settings to renew it, then reconnect. " \
          "The token value doesn't change, so there's no need to re-add the server."
      else
        "Unauthorized: invalid or missing authentication token"
      end
    end

    # Three ways in, and which of the last two applies depends on whether this
    # instance has users at all:
    #
    # 1. ENV["MCP_AUTH_TOKEN"] — always accepted, in every configuration. The
    #    headless path (cron, CI, scripts) and what existing clients were
    #    configured with. An env var can't be regenerated from a web page, which
    #    is why it isn't the only option.
    # 2. With OIDC: a per-user McpToken, whose owner must still satisfy the
    #    allowlist. Checked per request, so dropping an address from
    #    SPLAT_ALLOWED_USERS / SPLAT_ALLOWED_DOMAINS revokes it at once.
    # 3. Without OIDC: the shared instance token from settings. There are no
    #    users to attribute a token to, so one credential is all that's on offer.
    #
    # 2 and 3 are deliberately exclusive. Turning OIDC on retires the shared
    # token rather than leaving a second, unattributed way in — anyone who needs
    # one after that uses the env var, on purpose.
    #
    # Returns :ok, :expired (a real per-user token past its TTL), or :invalid.
    def mcp_auth_outcome(token)
      return :invalid if token.blank?

      env_token = ENV["MCP_AUTH_TOKEN"]
      if env_token.present? && ActiveSupport::SecurityUtils.secure_compare(token, env_token)
        return :ok
      end

      if SplatAuthorization.oidc_configured?
        result = McpToken.authenticate(token)
        return :ok if result.is_a?(McpToken)
        return :expired if result == :expired

        :invalid
      else
        instance_token_matches?(token) ? :ok : :invalid
      end
    end

    def instance_token_matches?(token)
      setting = Setting.instance
      return false unless setting.mcp_token_matches?(token)

      setting.touch_mcp_token_used!
      true
    end
  end
end
