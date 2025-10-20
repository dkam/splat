# frozen_string_literal: true

module Mcp
  class McpController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authenticate_mcp_token

    # Exception handling
    rescue_from StandardError do |exception|
      Rails.logger.error("MCP Error: #{exception.message}\n#{exception.backtrace.join("\n")}")
      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32603,
          message: "Internal server error",
          data: exception.message
        },
        id: @rpc_id
      }, status: 500
    end

    rescue_from ActiveRecord::RecordNotFound do |exception|
      Rails.logger.info("Record not found: #{exception.message}")
      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32602,
          message: "Resource not found",
          data: exception.message
        },
        id: @rpc_id
      }, status: :not_found
    end

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32700,
          message: "Parse error"
        },
        id: nil
      }, status: :bad_request
    end

    # Main entry point
    def handle_mcp_request
      request.body.rewind
      raw_body = request.body.read

      # Handle empty body (for GET or malformed requests)
      if raw_body.blank?
        rpc_request = params.as_json.except("controller", "action", "mcp")
      else
        rpc_request = JSON.parse(raw_body)
      end

      @rpc_id = rpc_request["id"]

      case rpc_request["method"]
      when "initialize"
        handle_initialize(rpc_request)
      when "notifications/initialized"
        handle_initialized_notification
      when "tools/list"
        handle_tools_list(rpc_request)
      when "tools/call"
        handle_tools_call(rpc_request)
      else
        render json: {
          jsonrpc: "2.0",
          error: {
            code: -32601,
            message: "Method not found: #{rpc_request["method"]}"
          },
          id: @rpc_id
        }, status: :bad_request
      end
    end

    private

    def authenticate_mcp_token
      token = request.headers["Authorization"]&.remove(/^Bearer\s+/i)

      unless valid_mcp_token?(token)
        render json: {
          jsonrpc: "2.0",
          error: {
            code: -32001,
            message: "Unauthorized: Invalid or missing authentication token"
          },
          id: nil
        }, status: :unauthorized
      end
    end

    def valid_mcp_token?(token)
      return false if token.blank?

      expected_token = ENV["MCP_AUTH_TOKEN"]
      return false if expected_token.blank?

      ActiveSupport::SecurityUtils.secure_compare(token, expected_token)
    end

    def handle_initialize(rpc_request)
      supported_version = "2024-11-05"

      render json: {
        jsonrpc: "2.0",
        id: rpc_request["id"],
        result: {
          protocolVersion: supported_version,
          capabilities: {
            tools: {}
          },
          serverInfo: {
            name: "splat",
            version: "1.0.0",
            description: "Splat Error Tracker MCP Server"
          }
        }
      }
    end

    def handle_initialized_notification
      # Client is ready - no response needed for notifications
      head :ok
    end

    def handle_tools_list(rpc_request)
      render json: {
        jsonrpc: "2.0",
        id: rpc_request["id"],
        result: {
          tools: tools_list
        }
      }
    end

    def handle_tools_call(rpc_request)
      params = rpc_request["params"]
      tool_name = params["name"]
      arguments = params["arguments"] || {}

      case tool_name
      when "list_recent_issues"
        list_recent_issues(arguments)
      when "search_issues"
        search_issues(arguments)
      when "get_issue"
        get_issue(arguments)
      when "get_issue_events"
        get_issue_events(arguments)
      when "get_event"
        get_event(arguments)
      when "get_transaction_stats"
        get_transaction_stats(arguments)
      when "search_slow_transactions"
        search_slow_transactions(arguments)
      when "get_transaction"
        get_transaction(arguments)
      else
        render json: {
          jsonrpc: "2.0",
          id: @rpc_id,
          error: {
            code: -32602,
            message: "Unknown tool: #{tool_name}"
          }
        }, status: :bad_request
      end
    end

    # Tool definitions
    def tools_list
      [
        {
          name: "list_recent_issues",
          description: "List the most recent issues, optionally filtered by status",
          inputSchema: {
            type: "object",
            properties: {
              status: {
                type: "string",
                description: "Filter by status: 'open', 'resolved', 'ignored', or 'all' (default: 'open')",
                enum: ["open", "resolved", "ignored", "all"]
              },
              limit: {
                type: "integer",
                description: "Maximum number of results (default: 20, max: 100)",
                default: 20
              }
            }
          }
        },
        {
          name: "search_issues",
          description: "Search for issues by keyword, status, or exception type",
          inputSchema: {
            type: "object",
            properties: {
              query: {
                type: "string",
                description: "Search query to match against issue title or exception type"
              },
              status: {
                type: "string",
                description: "Filter by status",
                enum: ["open", "resolved", "ignored"]
              },
              exception_type: {
                type: "string",
                description: "Filter by specific exception type"
              },
              limit: {
                type: "integer",
                description: "Maximum results (default: 20, max: 100)",
                default: 20
              }
            }
          }
        },
        {
          name: "get_issue",
          description: "Get detailed information about a specific issue by ID",
          inputSchema: {
            type: "object",
            properties: {
              issue_id: {
                type: "integer",
                description: "The ID of the issue"
              }
            },
            required: ["issue_id"]
          }
        },
        {
          name: "get_issue_events",
          description: "Get recent events (occurrences) for a specific issue",
          inputSchema: {
            type: "object",
            properties: {
              issue_id: {
                type: "integer",
                description: "The ID of the issue"
              },
              limit: {
                type: "integer",
                description: "Maximum events to return (default: 10, max: 50)",
                default: 10
              }
            },
            required: ["issue_id"]
          }
        },
        {
          name: "get_event",
          description: "Get detailed information about a specific event by ID, including full stack trace, request data, breadcrumbs, and user context",
          inputSchema: {
            type: "object",
            properties: {
              event_id: {
                type: "string",
                description: "The Sentry event ID (UUID format)"
              }
            },
            required: ["event_id"]
          }
        },
        {
          name: "get_transaction_stats",
          description: "Get performance statistics including percentiles and slowest endpoints",
          inputSchema: {
            type: "object",
            properties: {
              time_range_hours: {
                type: "integer",
                description: "Number of hours to look back (default: 24, max: 168)",
                default: 24
              },
              limit: {
                type: "integer",
                description: "Maximum number of slowest endpoints (default: 10, max: 50)",
                default: 10
              }
            }
          }
        },
        {
          name: "search_slow_transactions",
          description: "Search for slow transactions (>1 second by default)",
          inputSchema: {
            type: "object",
            properties: {
              min_duration_ms: {
                type: "integer",
                description: "Minimum duration in milliseconds (default: 1000)",
                default: 1000
              },
              endpoint: {
                type: "string",
                description: "Filter by endpoint name (partial match)"
              },
              http_status: {
                type: "string",
                description: "Filter by HTTP status code"
              },
              http_method: {
                type: "string",
                description: "Filter by HTTP method"
              },
              environment: {
                type: "string",
                description: "Filter by environment"
              },
              time_range_hours: {
                type: "integer",
                description: "Number of hours to look back (default: 24, max: 168)",
                default: 24
              },
              limit: {
                type: "integer",
                description: "Maximum results (default: 20, max: 100)",
                default: 20
              }
            }
          }
        },
        {
          name: "get_transaction",
          description: "Get detailed information about a specific transaction by ID",
          inputSchema: {
            type: "object",
            properties: {
              transaction_id: {
                type: "integer",
                description: "The database ID of the transaction"
              }
            },
            required: ["transaction_id"]
          }
        }
      ]
    end

    # Tool implementations
    def list_recent_issues(args)
      status = args["status"] || "open"
      limit = [[args["limit"]&.to_i || 20, 1].max, 100].min

      issues = Issue.includes(:project).recent
      issues = issues.where(status: status) unless status == "all"
      issues = issues.limit(limit)

      text = format_issues_list(issues, status)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def search_issues(args)
      query = args["query"]
      status = args["status"]
      exception_type = args["exception_type"]
      limit = [[args["limit"]&.to_i || 20, 1].max, 100].min

      issues = Issue.includes(:project).recent
      issues = issues.where("title LIKE ? OR exception_type LIKE ?", "%#{query}%", "%#{query}%") if query.present?
      issues = issues.where(status: status) if status.present?
      issues = issues.where(exception_type: exception_type) if exception_type.present?
      issues = issues.limit(limit)

      text = format_issues_list(issues)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def get_issue(args)
      issue = Issue.includes(:project).find(args["issue_id"])
      recent_event = issue.events.order(timestamp: :desc).first

      text = format_issue_detail(issue, recent_event)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def get_issue_events(args)
      issue = Issue.find(args["issue_id"])
      limit = [[args["limit"]&.to_i || 10, 1].max, 50].min
      events = issue.events.order(timestamp: :desc).limit(limit)

      text = format_issue_events(issue, events)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def get_event(args)
      event = Event.includes(:issue, :project).find_by!(event_id: args["event_id"])

      text = format_event_detail(event)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def get_transaction_stats(args)
      time_range_hours = [[args["time_range_hours"]&.to_i || 24, 1].max, 168].min
      limit = [[args["limit"]&.to_i || 10, 1].max, 50].min

      time_range = time_range_hours.hours.ago..Time.current

      percentiles = Transaction.percentiles(time_range)
      slowest_endpoints = Transaction.stats_by_endpoint(time_range).limit(limit)
      total_count = Transaction.where(timestamp: time_range).count

      text = format_transaction_stats(percentiles, slowest_endpoints, total_count, time_range_hours)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def search_slow_transactions(args)
      min_duration_ms = [args["min_duration_ms"]&.to_i || 1000, 0].max
      endpoint = args["endpoint"]
      http_status = args["http_status"]
      http_method = args["http_method"]
      environment = args["environment"]
      time_range_hours = [[args["time_range_hours"]&.to_i || 24, 1].max, 168].min
      limit = [[args["limit"]&.to_i || 20, 1].max, 100].min

      transactions = Transaction.includes(:project)
        .where("timestamp > ?", time_range_hours.hours.ago)
        .where("duration >= ?", min_duration_ms)
        .order(duration: :desc)

      transactions = transactions.where("transaction_name LIKE ?", "%#{endpoint}%") if endpoint.present?
      transactions = transactions.where(http_status: http_status) if http_status.present?
      transactions = transactions.where(http_method: http_method) if http_method.present?
      transactions = transactions.where(environment: environment) if environment.present?
      transactions = transactions.limit(limit)

      text = format_slow_transactions(transactions, min_duration_ms, time_range_hours)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    def get_transaction(args)
      transaction = Transaction.includes(:project).find(args["transaction_id"])

      text = format_transaction_detail(transaction)

      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{ type: "text", text: text }]
        }
      }
    end

    # Formatting helpers
    def format_issues_list(issues, status_filter = nil)
      if issues.empty?
        status_text = status_filter ? " with status '#{status_filter}'" : ""
        return "No issues found#{status_text}."
      end

      result = "## Recent Issues\n\n"
      result += "Showing #{issues.size} issue(s):\n\n"

      issues.each do |issue|
        result += "**Issue ##{issue.id}** - #{issue.title}\n"
        result += "  - Exception Type: #{issue.exception_type}\n"
        result += "  - Status: #{issue.status}\n"
        result += "  - Count: #{issue.count} occurrence(s)\n"
        result += "  - Last Seen: #{issue.last_seen.strftime('%Y-%m-%d %H:%M:%S')}\n"
        result += "  - Project: #{issue.project.name}\n\n"
      end

      result
    end

    def format_issue_detail(issue, recent_event)
      result = "## Issue ##{issue.id}: #{issue.title}\n\n"
      result += "**Exception Type:** #{issue.exception_type}\n"
      result += "**Status:** #{issue.status}\n"
      result += "**Occurrences:** #{issue.count}\n"
      result += "**First Seen:** #{issue.first_seen.strftime('%Y-%m-%d %H:%M:%S')}\n"
      result += "**Last Seen:** #{issue.last_seen.strftime('%Y-%m-%d %H:%M:%S')}\n"
      result += "**Project:** #{issue.project.name}\n\n"

      if recent_event
        result += "### Most Recent Stack Trace\n\n"
        frames = recent_event.payload.dig("exception", "values", 0, "stacktrace", "frames")

        if frames.present?
          result += "```\n"
          frames.reverse.each do |frame|
            filename = frame["filename"] || "unknown"
            lineno = frame["lineno"] || "?"
            function = frame["function"] || "unknown"
            result += "  at #{function} (#{filename}:#{lineno})\n"
          end
          result += "```\n"
        end
      end

      result
    end

    def format_issue_events(issue, events)
      result = "## Events for Issue ##{issue.id}: #{issue.title}\n\n"
      result += "Showing #{events.size} most recent event(s):\n\n"

      if events.empty?
        result += "No events found for this issue.\n"
      else
        events.each_with_index do |event, index|
          result += "### Event #{index + 1}\n"
          result += "**Event ID:** #{event.event_id}\n"
          result += "**Timestamp:** #{event.timestamp.strftime('%Y-%m-%d %H:%M:%S')}\n"
          result += "**Environment:** #{event.payload['environment']}\n" if event.payload["environment"]
          result += "**Server:** #{event.payload['server_name']}\n" if event.payload["server_name"]
          result += "\n"
        end
      end

      result
    end

    def format_event_detail(event)
      result = "## Event: #{event.event_id}\n\n"
      result += "**Timestamp:** #{event.timestamp.strftime('%Y-%m-%d %H:%M:%S')}\n"
      result += "**Project:** #{event.project.name}\n"
      result += "**Environment:** #{event.environment}\n" if event.environment
      result += "**Release:** #{event.release}\n" if event.release
      result += "**Server:** #{event.server_name}\n" if event.server_name
      result += "**Platform:** #{event.platform}\n" if event.platform
      result += "**Issue:** ##{event.issue.id} - #{event.issue.title}\n" if event.issue
      result += "\n"

      # Exception details
      exception_details = event.exception_details
      if exception_details[:type] || exception_details[:value]
        result += "### Exception\n\n"
        result += "**Type:** #{exception_details[:type]}\n" if exception_details[:type]
        result += "**Message:** #{exception_details[:value]}\n" if exception_details[:value]
        result += "\n"
      end

      # Stack trace
      if exception_details[:stacktrace]&.dig("frames")
        result += "### Stack Trace\n\n"
        result += "```\n"
        exception_details[:stacktrace]["frames"].reverse.each do |frame|
          filename = frame["filename"] || "unknown"
          lineno = frame["lineno"] || "?"
          function = frame["function"] || "unknown"
          result += "  at #{function} (#{filename}:#{lineno})\n"
        end
        result += "```\n\n"
      end

      # Request details
      request_data = event.request
      if request_data.present?
        result += "### Request\n\n"
        result += "**URL:** #{request_data['url']}\n" if request_data["url"]
        result += "**Method:** #{request_data['method']}\n" if request_data["method"]
        result += "**Query String:** #{request_data['query_string']}\n" if request_data["query_string"].present?

        # Request ID (common in Rails apps)
        if request_data["headers"]
          headers = request_data["headers"]
          request_id = headers["X-Request-Id"] || headers["x-request-id"] || headers["REQUEST_ID"]
          result += "**Request ID:** #{request_id}\n" if request_id
        end

        result += "\n"
      end

      # User context (sanitized)
      user_data = event.user
      if user_data.present?
        result += "### User Context\n\n"
        result += "**ID:** #{user_data['id']}\n" if user_data["id"]
        result += "**Email:** #{user_data['email']}\n" if user_data["email"]
        result += "**IP:** #{user_data['ip_address']}\n" if user_data["ip_address"]
        result += "\n"
      end

      # Tags
      tags = event.tags
      if tags.present?
        result += "### Tags\n\n"
        tags.each do |key, value|
          result += "- **#{key}:** #{value}\n"
        end
        result += "\n"
      end

      # Breadcrumbs (last 10)
      breadcrumbs = event.breadcrumbs
      if breadcrumbs.present? && breadcrumbs.any?
        result += "### Breadcrumbs (Last #{[breadcrumbs.size, 10].min})\n\n"
        breadcrumbs.last(10).each do |crumb|
          timestamp = crumb["timestamp"] ? Time.at(crumb["timestamp"]).strftime('%H:%M:%S') : "?"
          category = crumb["category"] || "default"
          message = crumb["message"] || crumb["type"] || "No message"
          result += "- **[#{timestamp}]** #{category}: #{message}\n"
        end
        result += "\n"
      end

      # Runtime context
      contexts = event.contexts
      if contexts.present?
        result += "### Runtime Context\n\n"

        if contexts["runtime"]
          runtime = contexts["runtime"]
          result += "**Runtime:** #{runtime['name']} #{runtime['version']}\n" if runtime["name"]
        end

        if contexts["os"]
          os = contexts["os"]
          result += "**OS:** #{os['name']} #{os['version']}\n" if os["name"]
        end

        if contexts["device"]
          device = contexts["device"]
          result += "**Device:** #{device['model']}\n" if device["model"]
        end
      end

      result
    end

    def format_transaction_stats(percentiles, slowest_endpoints, total_count, time_range_hours)
      result = "## Transaction Performance Statistics\n\n"
      result += "**Time Range:** Last #{time_range_hours} hour(s)\n"
      result += "**Total Transactions:** #{total_count}\n\n"

      if percentiles.empty?
        result += "No transaction data available.\n"
        return result
      end

      result += "### Response Time Percentiles\n\n"
      result += "- **Average:** #{percentiles[:avg].round}ms\n"
      result += "- **Median (P50):** #{percentiles[:p50].round}ms\n"
      result += "- **P95:** #{percentiles[:p95].round}ms\n"
      result += "- **P99:** #{percentiles[:p99].round}ms\n\n"

      if slowest_endpoints.any?
        result += "### Slowest Endpoints\n\n"
        slowest_endpoints.each do |endpoint|
          result += "- **#{endpoint.transaction_name}** - Avg: #{endpoint.avg_duration.to_f.round}ms (#{endpoint.count} requests)\n"
        end
      end

      result
    end

    def format_slow_transactions(transactions, min_duration_ms, time_range_hours)
      if transactions.empty?
        return "No slow transactions found (≥#{min_duration_ms}ms) in the last #{time_range_hours} hour(s)."
      end

      result = "## Slow Transactions (≥#{min_duration_ms}ms)\n\n"
      result += "Found #{transactions.size} transaction(s):\n\n"

      transactions.each do |txn|
        result += "**Transaction ##{txn.id}** - #{txn.transaction_name}\n"
        result += "  - Duration: #{txn.duration.round}ms\n"
        result += "  - Timestamp: #{txn.timestamp.strftime('%Y-%m-%d %H:%M:%S')}\n"
        result += "  - HTTP: #{txn.http_method} #{txn.http_status}\n" if txn.http_method || txn.http_status
        result += "  - Environment: #{txn.environment}\n" if txn.environment
        result += "  - Project: #{txn.project.name}\n\n"
      end

      result
    end

    def format_transaction_detail(txn)
      result = "## Transaction ##{txn.id}: #{txn.transaction_name}\n\n"
      result += "**Duration:** #{txn.duration.round}ms\n"
      result += "**Timestamp:** #{txn.timestamp.strftime('%Y-%m-%d %H:%M:%S')}\n"
      result += "**Project:** #{txn.project.name}\n"
      result += "**Environment:** #{txn.environment}\n" if txn.environment

      if txn.db_time || txn.view_time
        result += "\n### Time Breakdown\n"
        result += "- Database: #{txn.db_time.round}ms (#{txn.db_overhead_percentage}%)\n" if txn.db_time
        result += "- View: #{txn.view_time.round}ms (#{txn.view_overhead_percentage}%)\n" if txn.view_time
        result += "- Other: #{txn.other_time.round}ms\n" if txn.other_time > 0
      end

      if txn.http_method || txn.http_status
        result += "\n### HTTP Request\n"
        result += "- Method: #{txn.http_method}\n" if txn.http_method
        result += "- Status: #{txn.http_status}\n" if txn.http_status
        result += "- URL: #{txn.http_url}\n" if txn.http_url
      end

      result
    end
  end
end
