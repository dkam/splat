# frozen_string_literal: true

module Mcp
  class McpController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
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
      rpc_request = if raw_body.blank?
        params.as_json.except("controller", "action", "mcp")
      else
        JSON.parse(raw_body)
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
      when "get_transaction_spans"
        get_transaction_spans(arguments)
      when "get_endpoint_summary"
        get_endpoint_summary(arguments)
      when "get_endpoint_timeseries"
        get_endpoint_timeseries(arguments)
      when "find_n_plus_one_endpoints"
        find_n_plus_one_endpoints(arguments)
      when "get_transactions_by_endpoint"
        get_transactions_by_endpoint(arguments)
      when "compare_endpoint_performance"
        compare_endpoint_performance(arguments)
      when "resolve_issue"
        resolve_issue(arguments)
      when "ignore_issue"
        ignore_issue(arguments)
      when "reopen_issue"
        reopen_issue(arguments)
      when "search_logs"
        search_logs(arguments)
      when "get_log"
        get_log(arguments)
      when "get_trace_logs"
        get_trace_logs(arguments)
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
          description: "Get overall performance percentiles plus the top endpoints ranked by total time spent (avg duration × request count). Use this to find where the app is actually spending its time, not just where individual outliers are slow. Each endpoint includes time_spent, avg, p95, and request count.",
          inputSchema: {
            type: "object",
            properties: {
              endpoint: {
                type: "string",
                description: "Filter the overall percentile block to one endpoint (e.g., 'AlertsController#index'). The top-endpoints list is always project-wide."
              },
              time_range_hours: {
                type: "integer",
                description: "Number of hours to look back (default: 24, max: 168)",
                default: 24
              },
              limit: {
                type: "integer",
                description: "Maximum number of top endpoints to return (default: 10, max: 50)",
                default: 10
              }
            }
          }
        },
        {
          name: "find_n_plus_one_endpoints",
          description: "List endpoints where transactions show N+1 query patterns (the same SQL pattern repeated >3 times in one request). Ranked by number of affected transactions. Returns N+1 count, total count, % affected, avg/max queries per request, and avg/p95 duration. Use this to find endpoints that need eager-loading or query consolidation.",
          inputSchema: {
            type: "object",
            properties: {
              time_range_hours: {
                type: "integer",
                description: "Number of hours to look back (default: 24, max: 168)",
                default: 24
              },
              environment: {
                type: "string",
                description: "Filter by environment (optional)"
              },
              limit: {
                type: "integer",
                description: "Maximum endpoints to return (default: 20, max: 100)",
                default: 20
              }
            }
          }
        },
        {
          name: "get_endpoint_timeseries",
          description: "Time-bucketed metrics (count, avg, p50, p95, p99) for a single endpoint over a time range. Useful for spotting regressions ('did p95 jump after the 14:00 deploy?') or load patterns. Missing buckets are zero-filled.",
          inputSchema: {
            type: "object",
            properties: {
              endpoint: {
                type: "string",
                description: "Endpoint name (e.g., 'AlertsController#index')"
              },
              hours: {
                type: "integer",
                description: "Time range in hours (default: 24, max: 168)",
                default: 24
              },
              buckets: {
                type: "integer",
                description: "Number of buckets to split the range into (default: 24 → 1-hour buckets for a 24h range; min: 4, max: 168)",
                default: 24
              },
              environment: {
                type: "string",
                description: "Filter by environment (optional)"
              },
              release: {
                type: "string",
                description: "Filter by application version/release (optional)"
              }
            },
            required: ["endpoint"]
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
                description: "Filter by endpoint name (case-insensitive substring match, e.g. 'works' matches 'WorksController#show')"
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
              },
              tags: {
                type: "object",
                description: "Filter by Sentry tags. Keys are AND'd; string equality. " \
                             "Example: {\"user_id\":\"123\",\"environment\":\"production\"}",
                additionalProperties: {type: "string"}
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
                type: "string",
                description: "Either the internal numeric ID (e.g. '12345') or the Sentry transaction UUID (32 hex chars, e.g. 'abc123...'). UUIDs match the event_id used by get_event."
              }
            },
            required: ["transaction_id"]
          }
        },
        {
          name: "get_transaction_spans",
          description: "Get the per-span waterfall for a single transaction. Each span is one timed operation inside the request — a SQL query, an outbound HTTP call, a view render, a cache hit. Span descriptions retain table and column names (e.g. `SELECT \"covers\".* FROM \"covers\" WHERE \"covers\".\"id\" = ?`), unlike the aggregated query_patterns on get_transaction where identifiers are also stripped. Use this when get_transaction shows N+1 patterns but you can't tell which association is firing — span descriptions disambiguate. Returns: op summary (count + total time per op type), repeated descriptions (the classic N+1 fingerprint), and a depth-indented span list.",
          inputSchema: {
            type: "object",
            properties: {
              transaction_id: {
                type: "string",
                description: "Either the internal numeric ID or the Sentry transaction UUID — same value accepted by get_transaction."
              },
              op_filter: {
                type: "string",
                description: "Filter spans by op prefix (e.g. 'db' for all db.* spans, 'db.sql' for SQL only, 'http' for outbound HTTP, 'view' for renders). Default: no filter."
              },
              limit: {
                type: "integer",
                description: "Max spans to render in the list (default: 100, max: 1000). Op summary and repeated-description sections always cover all spans.",
                default: 100
              }
            },
            required: ["transaction_id"]
          }
        },
        {
          name: "get_endpoint_summary",
          description: "Get comprehensive statistics for a specific endpoint",
          inputSchema: {
            type: "object",
            properties: {
              endpoint: {
                type: "string",
                description: "Endpoint name (e.g., 'AlertsController#index')"
              },
              hours: {
                type: "integer",
                description: "Time range in hours (default: 24, max: 168)",
                default: 24
              },
              environment: {
                type: "string",
                description: "Filter by environment (optional)"
              },
              release: {
                type: "string",
                description: "Filter by application version/release (optional)"
              }
            },
            required: ["endpoint"]
          }
        },
        {
          name: "get_transactions_by_endpoint",
          description: "Get recent transactions for a specific endpoint without duration filter",
          inputSchema: {
            type: "object",
            properties: {
              endpoint: {
                type: "string",
                description: "Endpoint name (e.g., 'AlertsController#index')"
              },
              limit: {
                type: "integer",
                description: "Number of results (default: 20, max: 100)",
                default: 20
              },
              hours: {
                type: "integer",
                description: "Time range in hours (default: 24, max: 168)",
                default: 24
              },
              environment: {
                type: "string",
                description: "Filter by environment (optional)"
              },
              release: {
                type: "string",
                description: "Filter by application version/release (optional)"
              }
            },
            required: ["endpoint"]
          }
        },
        {
          name: "compare_endpoint_performance",
          description: "Compare endpoint performance before/after a version or timestamp",
          inputSchema: {
            type: "object",
            properties: {
              endpoint: {
                type: "string",
                description: "Endpoint name (e.g., 'AlertsController#index')"
              },
              before_release: {
                type: "string",
                description: "Application version before comparison (mutually exclusive with before_timestamp)"
              },
              after_release: {
                type: "string",
                description: "Application version after comparison (mutually exclusive with after_timestamp)"
              },
              before_timestamp: {
                type: "string",
                description: "ISO timestamp before comparison (mutually exclusive with before_release)"
              },
              after_timestamp: {
                type: "string",
                description: "ISO timestamp after comparison (mutually exclusive with after_release)"
              },
              hours_before: {
                type: "integer",
                description: "Hours before comparison point (default: 24, max: 168)",
                default: 24
              },
              hours_after: {
                type: "integer",
                description: "Hours after comparison point (default: 24, max: 168)",
                default: 24
              },
              environment: {
                type: "string",
                description: "Filter by environment (optional)"
              }
            },
            required: ["endpoint"]
          }
        },
        {
          name: "resolve_issue",
          description: "Mark an issue as resolved",
          inputSchema: {
            type: "object",
            properties: {
              issue_id: {
                type: "integer",
                description: "The ID of the issue to resolve"
              }
            },
            required: ["issue_id"]
          }
        },
        {
          name: "ignore_issue",
          description: "Mark an issue as ignored (won't auto-reopen on new events)",
          inputSchema: {
            type: "object",
            properties: {
              issue_id: {
                type: "integer",
                description: "The ID of the issue to ignore"
              }
            },
            required: ["issue_id"]
          }
        },
        {
          name: "reopen_issue",
          description: "Reopen a resolved or ignored issue",
          inputSchema: {
            type: "object",
            properties: {
              issue_id: {
                type: "integer",
                description: "The ID of the issue to reopen"
              }
            },
            required: ["issue_id"]
          }
        },
        {
          name: "search_logs",
          description: "Search structured logs (from Sentry Logs or OTLP) by level, logger, trace, environment, or message text",
          inputSchema: {
            type: "object",
            properties: {
              query: {
                type: "string",
                description: "Substring to match against the log message body"
              },
              level: {
                type: "string",
                description: "Filter by severity level",
                enum: %w[trace debug info warn error fatal]
              },
              logger: {
                type: "string",
                description: "Filter by logger name"
              },
              trace_id: {
                type: "string",
                description: "Filter to a single trace"
              },
              environment: {
                type: "string",
                description: "Filter by environment (e.g. production)"
              },
              time_range_hours: {
                type: "integer",
                description: "Look back this many hours (default: 24, max: 168)",
                default: 24
              },
              limit: {
                type: "integer",
                description: "Maximum results (default: 50, max: 200)",
                default: 50
              }
            }
          }
        },
        {
          name: "get_log",
          description: "Get a single log record by its log_id, including decompressed attributes",
          inputSchema: {
            type: "object",
            properties: {
              log_id: {
                type: "string",
                description: "The log_id (UUID) of the record"
              }
            },
            required: ["log_id"]
          }
        },
        {
          name: "get_trace_logs",
          description: "Get all log records sharing a trace_id, oldest first — ties logs to a transaction/trace",
          inputSchema: {
            type: "object",
            properties: {
              trace_id: {
                type: "string",
                description: "The trace_id to collect logs for"
              },
              limit: {
                type: "integer",
                description: "Maximum results (default: 100, max: 500)",
                default: 100
              }
            },
            required: ["trace_id"]
          }
        }
      ]
    end

    # Tool implementations
    def list_recent_issues(args)
      status = args["status"] || "open"
      limit = (args["limit"]&.to_i || 20).clamp(1, 100)

      issues = Issue.includes(:project).recent
      issues = issues.where(status: status) unless status == "all"
      issues = issues.limit(limit)

      text = format_issues_list(issues, status)

      render_text(text)
    end

    def search_issues(args)
      query = args["query"]
      status = args["status"]
      exception_type = args["exception_type"]
      limit = (args["limit"]&.to_i || 20).clamp(1, 100)

      issues = Issue.includes(:project).recent
      issues = issues.where("title LIKE ? OR exception_type LIKE ?", "%#{query}%", "%#{query}%") if query.present?
      issues = issues.where(status: status) if status.present?
      issues = issues.where(exception_type: exception_type) if exception_type.present?
      issues = issues.limit(limit)

      text = format_issues_list(issues)

      render_text(text)
    end

    def get_issue(args)
      issue = Issue.includes(:project).find(args["issue_id"])
      recent_event = issue.events.order(timestamp: :desc).first

      text = format_issue_detail(issue, recent_event)

      render_text(text)
    end

    def get_issue_events(args)
      issue = Issue.find(args["issue_id"])
      limit = (args["limit"]&.to_i || 10).clamp(1, 50)
      events = issue.events.order(timestamp: :desc).limit(limit)

      text = format_issue_events(issue, events)

      render_text(text)
    end

    def get_event(args)
      event = Event.includes(:issue, :project).find_by!(event_id: args["event_id"])

      text = format_event_detail(event)

      render_text(text)
    end

    def search_logs(args)
      time_range_hours = (args["time_range_hours"]&.to_i || 24).clamp(1, 168)
      limit = (args["limit"]&.to_i || 50).clamp(1, 200)

      logs = Log.where(timestamp: time_range_hours.hours.ago..Time.current).recent
      logs = logs.search_text(args["query"]) if args["query"].present?
      logs = logs.by_level(args["level"]) if args["level"].present? && Log.levels.key?(args["level"])
      logs = logs.by_logger(args["logger"]) if args["logger"].present?
      logs = logs.for_trace(args["trace_id"]).reorder(timestamp: :desc) if args["trace_id"].present?
      logs = logs.by_environment(args["environment"]) if args["environment"].present?
      logs = logs.limit(limit)

      render_text(format_logs_list(logs.to_a, time_range_hours))
    end

    def get_log(args)
      log = Log.find_by(log_id: args["log_id"])
      return render_error("Log not found: #{args["log_id"]}") unless log

      render_text(format_log_detail(log))
    end

    def get_trace_logs(args)
      trace_id = args["trace_id"]
      return render_error("trace_id is required") if trace_id.blank?

      limit = (args["limit"]&.to_i || 100).clamp(1, 500)
      logs = Log.for_trace(trace_id).limit(limit).to_a

      render_text(format_logs_list(logs, nil, header: "Logs for trace #{trace_id}"))
    end

    def get_transaction_stats(args)
      endpoint = args["endpoint"]
      time_range_hours = (args["time_range_hours"]&.to_i || 24).clamp(1, 168)
      limit = (args["limit"]&.to_i || 10).clamp(1, 50)

      time_range = time_range_hours.hours.ago..Time.current

      if endpoint.present?
        ep_stats = Transaction.percentiles_for_endpoint(endpoint, time_range)
        percentiles = {
          avg: ep_stats["avg_duration"]&.to_f || 0,
          p50: ep_stats["p50_duration"]&.to_f || 0,
          p95: ep_stats["p95_duration"]&.to_f || 0,
          p99: ep_stats["p99_duration"]&.to_f || 0,
          min: ep_stats["min_duration"]&.to_f || 0,
          max: ep_stats["max_duration"]&.to_f || 0
        }
        total_count = Transaction.where(transaction_name: endpoint, timestamp: time_range).count
      else
        percentiles = Transaction.percentiles(time_range)
        total_count = Transaction.where(timestamp: time_range).count
      end

      top_endpoints = Transaction.stats_by_endpoint_with_impact(time_range, limit: limit)

      text = format_transaction_stats(percentiles, top_endpoints, total_count, time_range_hours, endpoint)

      render_text(text)
    end

    def search_slow_transactions(args)
      min_duration_ms = [args["min_duration_ms"]&.to_i || 1000, 0].max
      endpoint = args["endpoint"]
      http_status = args["http_status"]
      http_method = args["http_method"]
      environment = args["environment"]
      time_range_hours = (args["time_range_hours"]&.to_i || 24).clamp(1, 168)
      limit = (args["limit"]&.to_i || 20).clamp(1, 100)

      tags = args["tags"]
      tags = nil unless tags.is_a?(Hash) && tags.any?
      if tags
        bad_key = tags.keys.find { |k| !k.is_a?(String) || k !~ /\A[a-zA-Z0-9_.-]+\z/ }
        return render_text("Invalid tag key: #{bad_key.inspect}") if bad_key
        tags = tags.transform_values(&:to_s)
      end

      rows = Transaction.slow(
        threshold_ms: min_duration_ms,
        time_range: time_range_hours.hours.ago..Time.current,
        transaction_name: endpoint,
        http_status: http_status,
        http_method: http_method,
        environment: environment,
        tags: tags,
        limit: limit
      )

      project_names = Project.where(id: rows.map(&:project_id).compact.uniq).pluck(:id, :name).to_h
      rows = rows.map do |r|
        h = r.attributes
        h["project_name"] = project_names[r.project_id]
        h
      end

      text = format_slow_transactions(rows, min_duration_ms, time_range_hours)

      render_text(text)
    end

    def get_transaction(args)
      transaction = find_transaction(args["transaction_id"])
      # trace_id is promoted onto the transaction row; the detail output uses it
      # to point an agent at get_trace_logs (mirrors the transaction→logs link
      # in the web UI).
      render_text(format_transaction_detail(transaction, transaction.trace_id))
    end

    def get_transaction_spans(args)
      transaction = find_transaction(args["transaction_id"])
      op_filter = args["op_filter"].to_s.strip
      limit = (args["limit"]&.to_i || 100).clamp(1, 1000)

      # Materialize a hash per span; duration_ms is a computed method, not
      # a column, so .attributes alone would miss it.
      all_spans = Span.for_transaction(
        transaction.transaction_id,
        project_id: transaction.project_id,
        near_timestamp: transaction.timestamp
      ).map { |s| s.attributes.merge("duration_ms" => s.duration_ms) }

      filtered = op_filter.present? ? all_spans.select { |s| s["op"].to_s.start_with?(op_filter) } : all_spans

      render_text(format_transaction_spans(transaction, all_spans, filtered, op_filter, limit))
    end

    def find_transaction(id)
      id_str = id.to_s
      if id_str.match?(/\A\d+\z/)
        Transaction.includes(:project).find(id_str)
      else
        Transaction.includes(:project).find_by!(transaction_id: id_str)
      end
    end

    def get_endpoint_summary(args)
      endpoint = args["endpoint"]
      hours = (args["hours"]&.to_i || 24).clamp(1, 168)
      environment = args["environment"]
      release = args["release"]
      time_range = hours.hours.ago..Time.current

      stats = Transaction.percentiles_for_endpoint(
        endpoint, time_range, environment: environment, release: release
      )
      total_count = stats["count"].to_i
      return render_text("No transactions found for endpoint '#{endpoint}' with the specified filters.") if total_count.zero?

      percentiles = {
        avg: stats["avg_duration"]&.to_f || 0,
        p50: stats["p50_duration"]&.to_f || 0,
        p95: stats["p95_duration"]&.to_f || 0,
        p99: stats["p99_duration"]&.to_f || 0,
        min: stats["min_duration"]&.to_f || 0,
        max: stats["max_duration"]&.to_f || 0
      }
      db_percentiles =
        if stats["avg_db_time"]
          {avg: stats["avg_db_time"].to_f, p95: stats["p95_db_time"]&.to_f || 0}
        end
      view_percentiles =
        if stats["avg_view_time"]
          {avg: stats["avg_view_time"].to_f, p95: stats["p95_view_time"]&.to_f || 0}
        end

      slowest_request = endpoint_extreme_row(endpoint, time_range, environment, release, :desc)
      fastest_request = endpoint_extreme_row(endpoint, time_range, environment, release, :asc)

      text = format_endpoint_summary(
        endpoint, total_count, hours, environment, release,
        percentiles, db_percentiles, view_percentiles,
        slowest_request, fastest_request
      )

      render_text(text)
    end

    def find_n_plus_one_endpoints(args)
      time_range_hours = (args["time_range_hours"]&.to_i || 24).clamp(1, 168)
      environment = args["environment"]
      limit = (args["limit"]&.to_i || 20).clamp(1, 100)
      time_range = time_range_hours.hours.ago..Time.current

      rows = Transaction.endpoints_by_n_plus_one(
        time_range, environment: environment, limit: limit
      )

      text = format_n_plus_one_endpoints(rows, time_range_hours, environment)

      render_text(text)
    end

    def get_endpoint_timeseries(args)
      endpoint = args["endpoint"]
      hours = (args["hours"]&.to_i || 24).clamp(1, 168)
      buckets = (args["buckets"]&.to_i || 24).clamp(4, 168)
      environment = args["environment"]
      release = args["release"]
      time_range = hours.hours.ago..Time.current

      series = Transaction.time_series_for_endpoint(
        endpoint, time_range,
        bucket_count: buckets, environment: environment, release: release
      )

      text = format_endpoint_timeseries(endpoint, series, hours, buckets, environment, release, time_range.begin)

      render_text(text)
    end

    def endpoint_extreme_row(endpoint, time_range, environment, release, direction)
      scope = Transaction.where(transaction_name: endpoint, timestamp: time_range)
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(release: release) if release.present?
      row = scope.order(duration: (direction == :desc) ? :desc : :asc).limit(1).first
      row && {"id" => row.id, "duration" => row.duration, "db_time" => row.db_time,
              "view_time" => row.view_time, "timestamp" => row.timestamp}
    end

    def get_transactions_by_endpoint(args)
      endpoint = args["endpoint"]
      limit = (args["limit"]&.to_i || 20).clamp(1, 100)
      hours = (args["hours"]&.to_i || 24).clamp(1, 168)
      environment = args["environment"]
      release = args["release"]

      transactions = Transaction.includes(:project)
        .where(transaction_name: endpoint)
        .where("timestamp > ?", hours.hours.ago)
        .order(timestamp: :desc)
        .limit(limit)

      transactions = transactions.where(environment: environment) if environment.present?
      transactions = transactions.where(release: release) if release.present?

      text = format_transactions_by_endpoint(transactions, endpoint, hours, environment, release)

      render_text(text)
    end

    def compare_endpoint_performance(args)
      endpoint = args["endpoint"]
      before_release = args["before_release"]
      after_release = args["after_release"]
      before_timestamp = args["before_timestamp"]
      after_timestamp = args["after_timestamp"]
      hours_before = (args["hours_before"]&.to_i || 24).clamp(1, 168)
      hours_after = (args["hours_after"]&.to_i || 24).clamp(1, 168)
      environment = args["environment"]

      # Validate input - either release-based or timestamp-based comparison
      if before_release.present? && after_release.present?
        # Version-based comparison
        before_transactions = get_transactions_by_filters(endpoint, hours_before, environment, before_release)
        after_transactions = get_transactions_by_filters(endpoint, hours_after, environment, after_release)
        comparison_type = "version"
        before_label = "Version #{before_release}"
        after_label = "Version #{after_release}"
      elsif before_timestamp.present? && after_timestamp.present?
        # Timestamp-based comparison
        before_time = Time.parse(before_timestamp)
        after_time = Time.parse(after_timestamp)

        before_transactions = get_transactions_by_time_range(endpoint, before_time - hours_before.hours, before_time, environment)
        after_transactions = get_transactions_by_time_range(endpoint, after_time, after_time + hours_after.hours, environment)
        comparison_type = "timestamp"
        before_label = "Before #{before_timestamp}"
        after_label = "After #{after_timestamp}"
      else
        return render_error("Please provide either both before_release/after_release OR both before_timestamp/after_timestamp for comparison.")
      end

      text = format_performance_comparison(
        endpoint, comparison_type, before_label, after_label,
        before_transactions, after_transactions
      )

      render_text(text)
    rescue ArgumentError
      render_error("Invalid timestamp format. Please use ISO format (e.g., '2025-10-21T03:00:00Z')")
    end

    def resolve_issue(args)
      issue = Issue.find(args["issue_id"])
      issue.resolved!
      render_text("✅ Issue ##{issue.id} marked as resolved")
    end

    def ignore_issue(args)
      issue = Issue.find(args["issue_id"])
      issue.ignored!
      render_text("🔕 Issue ##{issue.id} marked as ignored")
    end

    def reopen_issue(args)
      issue = Issue.find(args["issue_id"])
      issue.open!
      render_text("🔓 Issue ##{issue.id} reopened")
    end

    # Helper methods for new tools
    def calculate_percentiles(values)
      return {} if values.empty?

      {
        avg: values.sum / values.size,
        p50: values[values.size * 0.5],
        p95: values[values.size * 0.95],
        p99: values[values.size * 0.99],
        min: values.first,
        max: values.last
      }
    end

    # Returns a sorted array of durations from DuckLake, ready for percentile calc.
    def get_transactions_by_filters(endpoint, hours, environment, release)
      durations_for(
        endpoint,
        hours.hours.ago..Time.current,
        environment: environment,
        release: release
      )
    end

    def get_transactions_by_time_range(endpoint, start_time, end_time, environment)
      durations_for(endpoint, start_time..end_time, environment: environment)
    end

    def durations_for(endpoint, time_range, environment: nil, release: nil)
      scope = Transaction.where(transaction_name: endpoint, timestamp: time_range)
      scope = scope.where(environment: environment) if environment.present?
      scope = scope.where(release: release) if release.present?
      scope.pluck(:duration).sort
    end

    def format_logs_list(logs, time_range_hours, header: nil)
      if logs.empty?
        window = time_range_hours ? " in the last #{time_range_hours}h" : ""
        return "No logs found#{window}."
      end

      project_names = Project.where(id: logs.map(&:project_id).uniq).pluck(:id, :name).to_h
      title = header || "Recent Logs (last #{time_range_hours}h)"
      result = "## #{title}\n\nShowing #{logs.size} log(s):\n\n"
      logs.each do |log|
        result += "- **#{log.level.to_s.upcase}** #{log.timestamp.utc.strftime("%Y-%m-%d %H:%M:%S")} "
        result += "[#{project_names[log.project_id] || log.project_id}] #{log.body}\n"
        meta = []
        meta << "logger=#{log.logger_name}" if log.logger_name.present?
        meta << "env=#{log.environment}" if log.environment.present?
        meta << "trace=#{log.trace_id}" if log.trace_id.present?
        meta << "log_id=#{log.log_id}"
        result += "  #{meta.join(" · ")}\n"
      end
      result
    end

    def format_log_detail(log)
      result = "## Log #{log.log_id}\n\n"
      result += "- **Level:** #{log.level}\n"
      result += "- **Time:** #{log.timestamp.utc.iso8601}\n"
      result += "- **Body:** #{log.body}\n"
      result += "- **Logger:** #{log.logger_name}\n" if log.logger_name.present?
      result += "- **Environment:** #{log.environment}\n" if log.environment.present?
      result += "- **Release:** #{log.release}\n" if log.release.present?
      result += "- **Server:** #{log.server_name}\n" if log.server_name.present?
      result += "- **Source:** #{log.source}\n" if log.source.present?
      result += "- **Trace:** #{log.trace_id}\n" if log.trace_id.present?
      result += "- **Span:** #{log.span_id}\n" if log.span_id.present?

      attrs = log.payload_attributes
      if attrs.present? && attrs.any?
        result += "\n### Attributes\n\n"
        attrs.each do |k, v|
          val = (v.is_a?(Hash) && v.key?("value")) ? v["value"] : v
          result += "- **#{k}:** #{val}\n"
        end
      end
      result
    end

    def render_text(text)
      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        result: {
          content: [{type: "text", text: text}]
        }
      }
    end

    def render_error(message)
      render json: {
        jsonrpc: "2.0",
        id: @rpc_id,
        error: {
          code: -32602,
          message: message
        }
      }, status: :bad_request
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
        result += "  - Last Seen: #{issue.last_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
        result += "  - Project: #{issue.project.name}\n\n"
      end

      result
    end

    def format_issue_detail(issue, recent_event)
      result = "## Issue ##{issue.id}: #{issue.title}\n\n"
      result += "**Exception Type:** #{issue.exception_type}\n"
      result += "**Status:** #{issue.status}\n"
      result += "**Occurrences:** #{issue.count}\n"
      result += "**First Seen:** #{issue.first_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "**Last Seen:** #{issue.last_seen.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "**Project:** #{issue.project.name}\n\n"

      if recent_event&.payload
        result += "### Most Recent Stack Trace\n\n"
        frames = recent_event.payload.dig("exception", "values", 0, "stacktrace", "frames")

        if frames.present?
          result += "```\n"
          frames.reverse_each do |frame|
            filename = frame["filename"] || "unknown"
            lineno = frame["lineno"] || "?"
            function = frame["function"] || "unknown"
            result += "  at #{function} (#{filename}:#{lineno})\n"
          end
          result += "```\n"
        else
          result += "No stack trace available for this event.\n"
        end
      else
        result += "No events found for this issue.\n"
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
          result += "**Timestamp:** #{event.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
          result += "**Environment:** #{event.environment}\n" if event.environment.present?
          result += "**Server:** #{event.server_name}\n" if event.server_name.present?
          result += "\n"
        end
      end

      result
    end

    def format_event_detail(event)
      result = "## Event: #{event.event_id}\n\n"
      result += "**Timestamp:** #{event.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
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
        exception_details[:stacktrace]["frames"].reverse_each do |frame|
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
        result += "**URL:** #{request_data["url"]}\n" if request_data["url"]
        result += "**Method:** #{request_data["method"]}\n" if request_data["method"]
        result += "**Query String:** #{request_data["query_string"]}\n" if request_data["query_string"].present?

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
        result += "**ID:** #{user_data["id"]}\n" if user_data["id"]
        result += "**Email:** #{user_data["email"]}\n" if user_data["email"]
        result += "**IP:** #{user_data["ip_address"]}\n" if user_data["ip_address"]
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
          timestamp = crumb["timestamp"] ? Time.at(crumb["timestamp"]).strftime("%H:%M:%S") : "?"
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
          result += "**Runtime:** #{runtime["name"]} #{runtime["version"]}\n" if runtime["name"]
        end

        if contexts["os"]
          os = contexts["os"]
          result += "**OS:** #{os["name"]} #{os["version"]}\n" if os["name"]
        end

        if contexts["device"]
          device = contexts["device"]
          result += "**Device:** #{device["model"]}\n" if device["model"]
        end
      end

      result
    end

    def format_transaction_stats(percentiles, top_endpoints, total_count, time_range_hours, endpoint = nil)
      result = "## Transaction Performance Statistics\n\n"
      result += "**Endpoint:** #{endpoint}\n" if endpoint.present?
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

      if top_endpoints.any?
        result += "### Top Endpoints by Impact (avg × count)\n\n"
        result += "| Endpoint | Time Spent | Avg | P95 | Count |\n"
        result += "|---|---:|---:|---:|---:|\n"
        top_endpoints.each do |row|
          result += "| #{row["transaction_name"]} " \
                   "| #{format_ms(row["time_spent"])} " \
                   "| #{format_ms(row["avg_duration"])} " \
                   "| #{format_ms(row["p95_duration"])} " \
                   "| #{row["count"]} |\n"
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
        result += "**Transaction ##{txn["id"]}** - #{txn["transaction_name"]}\n"
        result += "  - Duration: #{txn["duration"].round}ms\n"
        result += "  - Timestamp: #{txn["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
        result += "  - HTTP: #{txn["http_method"]} #{txn["http_status"]}\n" if txn["http_method"] || txn["http_status"]
        result += "  - Environment: #{txn["environment"]}\n" if txn["environment"]
        result += "  - Project: #{txn["project_name"]}\n\n" if txn["project_name"]
      end

      result
    end

    def format_transaction_detail(txn, trace_id = nil)
      result = "## Transaction ##{txn.id}: #{txn.transaction_name}\n\n"
      result += "**Transaction UUID:** #{txn.transaction_id}\n"
      result += "**Duration:** #{txn.duration.round}ms\n"
      result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "**Project:** #{txn.project.name}\n"
      result += "**Environment:** #{txn.environment}\n" if txn.environment
      result += "**Release:** #{txn.release}\n" if txn.release
      result += "**Server:** #{txn.server_name}\n" if txn.server_name
      if trace_id.present?
        result += "**Trace:** #{trace_id}\n"
        result += "_Call `get_trace_logs` with this trace_id for the correlated log lines._\n"
      end

      if txn.db_time || txn.view_time
        result += "\n### Time Breakdown\n"
        result += "- Database: #{txn.db_time.round}ms (#{txn.db_overhead_percentage}%)\n" if txn.db_time
        result += "- View: #{txn.view_time.round}ms (#{txn.view_overhead_percentage}%)\n" if txn.view_time
        if txn.duration.to_i > 0
          other_pct = (txn.other_time.to_f / txn.duration * 100).round(2)
          result += "- Other (middleware/queue): #{txn.other_time.round}ms (#{other_pct}%)\n"
        end
      end

      if txn.http_method || txn.http_status || txn.http_url
        result += "\n### HTTP Request\n"
        result += "- Method: #{txn.http_method}\n" if txn.http_method
        result += "- Status: #{txn.http_status}\n" if txn.http_status
        result += "- URL: #{txn.http_url}\n" if txn.http_url

        query_params = parse_query_params(txn.http_url)
        if query_params.any?
          result += "- Query Params:\n"
          query_params.each { |k, v| result += "  - #{k}: #{v}\n" }
        end
      end

      if txn.query_count > 0
        result += "\n### Query Analysis\n"
        result += "- Total queries: #{txn.query_count}\n"
        result += "- Unique patterns: #{txn.unique_query_patterns}\n"
        if txn.has_n_plus_one_queries?
          result += "- ⚠️ Potential N+1 patterns (#{txn.potential_n_plus_one_queries.size}):\n"
          txn.potential_n_plus_one_queries.first(5).each do |pattern|
            count = txn.query_patterns.dig(pattern, "count")
            result += "  - `#{pattern}`#{" (×#{count})" if count}\n"
          end
        end
      end

      if txn.tags.is_a?(Hash) && txn.tags.any?
        result += "\n### Tags\n"
        txn.tags.each { |k, v| result += "- **#{k}:** #{v}\n" }
      end

      result
    end

    def format_transaction_spans(txn, all_spans, filtered_spans, op_filter, limit)
      result = "## Spans for Transaction ##{txn.id}: #{txn.transaction_name}\n\n"
      result += "**Transaction UUID:** #{txn.transaction_id}\n"
      result += "**Duration:** #{txn.duration.round}ms\n"
      result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
      result += "**Total Spans:** #{all_spans.size}"
      result += " (truncated at ingest — cap is #{Transaction::SPAN_CAP} per transaction)" if txn.spans_truncated
      result += "\n"
      result += "**Op Filter:** `#{op_filter}*`\n" if op_filter.present?
      result += "\n"

      if all_spans.empty?
        result += "No spans recorded for this transaction. Either the SDK didn't capture child spans, or the transaction is older than the span retention window.\n"
        return result
      end

      # Op summary across ALL spans (not filtered) — gives a holistic view
      by_op = all_spans.group_by { |s| s["op"].to_s }
      result += "### Op Summary\n\n"
      result += "| Op | Count | Total Time | Avg |\n"
      result += "|---|---:|---:|---:|\n"
      by_op.sort_by { |_, ss| -ss.sum { |s| s["duration_ms"].to_f } }.each do |op, ss|
        total = ss.sum { |s| s["duration_ms"].to_f }
        avg = total / ss.size
        op_label = op.presence || "(none)"
        result += "| `#{op_label}` | #{ss.size} | #{format_ms(total)} | #{format_ms(avg)} |\n"
      end
      result += "\n"

      # Repeated descriptions within the filtered set — N+1 fingerprint
      repeated = filtered_spans
        .select { |s| s["description"].to_s.strip.present? }
        .group_by { |s| s["description"].to_s }
        .select { |_, ss| ss.size > 3 }
        .sort_by { |_, ss| -ss.size }

      if repeated.any?
        result += "### Repeated Descriptions (potential N+1)\n\n"
        result += "Descriptions executed >3 times in this request:\n\n"
        repeated.first(15).each do |desc, ss|
          total = ss.sum { |s| s["duration_ms"].to_f }
          op = ss.first["op"]
          truncated = (desc.size > 400) ? "#{desc[0, 400]}…" : desc
          result += "- **×#{ss.size}** (#{format_ms(total)} total) `#{op}`\n"
          result += "  ```sql\n  #{truncated}\n  ```\n"
        end
        result += "\n"
      end

      # Span list
      shown = filtered_spans.first(limit)
      list_label = if op_filter.present?
        "Span List (filtered by op `#{op_filter}*`: #{shown.size} of #{filtered_spans.size}; #{all_spans.size} total)"
      else
        "Span List (#{shown.size} of #{all_spans.size})"
      end
      result += "### #{list_label}\n\n"

      shown.each do |s|
        depth = s["depth"].to_i
        indent = "  " * depth
        op = s["op"].to_s.presence || "(none)"
        desc = s["description"].to_s
        dur = s["duration_ms"].to_f
        line = "#{indent}- [#{format_ms(dur)}] `#{op}`"
        if desc.present?
          desc_truncated = (desc.size > 250) ? "#{desc[0, 250]}…" : desc
          line += " — #{desc_truncated}"
        end
        result += "#{line}\n"
      end

      if filtered_spans.size > limit
        result += "\n_#{filtered_spans.size - limit} more spans not shown — increase `limit` or narrow `op_filter`._\n"
      end

      result
    end

    def parse_query_params(url)
      return {} if url.blank? || !url.include?("?")
      query = url.split("?", 2).last
      URI.decode_www_form(query).to_h
    rescue ArgumentError
      {}
    end

    def format_endpoint_summary(endpoint, total_count, hours, environment, release,
      percentiles, db_percentiles, view_percentiles,
      slowest_request, fastest_request)
      result = "## Endpoint Summary: #{endpoint}\n\n"
      result += "**Total Requests:** #{total_count}\n"
      result += "**Time Range:** Last #{hours} hour(s)\n"
      result += "**Environment:** #{environment}\n" if environment.present?
      result += "**Release:** #{release}\n" if release.present?
      result += "\n"

      # Overall performance
      result += "### Response Time Performance\n\n"
      result += "- **Average:** #{percentiles[:avg]&.round}ms\n"
      result += "- **Median (P50):** #{percentiles[:p50]&.round}ms\n"
      result += "- **P95:** #{percentiles[:p95]&.round}ms\n"
      result += "- **P99:** #{percentiles[:p99]&.round}ms\n"
      result += "- **Min:** #{percentiles[:min]&.round}ms\n"
      result += "- **Max:** #{percentiles[:max]&.round}ms\n\n"

      # Database performance
      if db_percentiles&.any?
        result += "### Database Performance\n\n"
        result += "- **Avg DB Time:** #{db_percentiles[:avg]&.round}ms\n"
        result += "- **P95 DB Time:** #{db_percentiles[:p95]&.round}ms\n\n"
      end

      # View performance
      if view_percentiles&.any?
        result += "### View Rendering Performance\n\n"
        result += "- **Avg View Time:** #{view_percentiles[:avg]&.round}ms\n"
        result += "- **P95 View Time:** #{view_percentiles[:p95]&.round}ms\n\n"
      end

      # Extreme examples
      result += "### Sample Requests\n\n"
      if fastest_request
        result += "**Fastest Request:** #{fastest_request["duration"].round}ms"
        result += " (DB: #{fastest_request["db_time"].round}ms)" if fastest_request["db_time"]
        result += " (View: #{fastest_request["view_time"].round}ms)" if fastest_request["view_time"]
        result += " - #{fastest_request["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
      end

      if slowest_request
        result += "**Slowest Request:** #{slowest_request["duration"].round}ms"
        result += " (DB: #{slowest_request["db_time"].round}ms)" if slowest_request["db_time"]
        result += " (View: #{slowest_request["view_time"].round}ms)" if slowest_request["view_time"]
        result += " - #{slowest_request["timestamp"].strftime("%Y-%m-%d %H:%M:%S")}\n"
      end

      result
    end

    def format_n_plus_one_endpoints(rows, hours, environment)
      header = "## Endpoints with N+1 Query Issues\n\n"
      header += "**Time Range:** Last #{hours} hour(s)\n"
      header += "**Environment:** #{environment}\n" if environment.present?
      header += "\n"

      if rows.empty?
        return header + "No N+1 patterns detected in this window.\n"
      end

      header += "| Endpoint | N+1 / Total | % Affected | Avg Queries | Max Queries | Avg | P95 |\n"
      header += "|---|---:|---:|---:|---:|---:|---:|\n"
      rows.each do |r|
        header += "| #{r["transaction_name"]} " \
                 "| #{r["n_plus_one_count"]} / #{r["total_count"]} " \
                 "| #{r["n_plus_one_pct"]}% " \
                 "| #{r["avg_queries"].to_f.round(1)} " \
                 "| #{r["max_queries"]} " \
                 "| #{format_ms(r["avg_duration"])} " \
                 "| #{format_ms(r["p95_duration"])} |\n"
      end
      header
    end

    def format_endpoint_timeseries(endpoint, series, hours, buckets, environment, release, start_time)
      bucket_seconds = hours * 3600.0 / buckets
      bucket_minutes = (bucket_seconds / 60.0).round

      header = "## Endpoint Time Series: #{endpoint}\n\n"
      header += "**Time Range:** Last #{hours} hour(s)\n"
      header += "**Buckets:** #{buckets} × #{bucket_minutes}m\n"
      header += "**Environment:** #{environment}\n" if environment.present?
      header += "**Release:** #{release}\n" if release.present?
      header += "\n"

      # time_series_for_endpoint returns string-keyed buckets: an integer
      # "bucket" index plus "count" and "p50"/"p95"/"p99" (no avg/max). Derive
      # each bucket's wall-clock start from its index and the window origin.
      if series.all? { |b| b["count"].zero? }
        return header + "No requests in this window.\n"
      end

      header += "| Bucket Start | Count | P50 | P95 | P99 |\n"
      header += "|---|---:|---:|---:|---:|\n"
      series.each do |b|
        bucket_start = start_time + (b["bucket"] * bucket_seconds)
        header += "| #{bucket_start.strftime("%Y-%m-%d %H:%M")} " \
                 "| #{b["count"]} " \
                 "| #{format_ms(b["p50"])} " \
                 "| #{format_ms(b["p95"])} " \
                 "| #{format_ms(b["p99"])} |\n"
      end
      header
    end

    def format_ms(value)
      return "—" if value.nil?
      "#{value.to_f.round}ms"
    end

    def format_transactions_by_endpoint(transactions, endpoint, hours, environment, release)
      if transactions.empty?
        result = "No transactions found for endpoint '#{endpoint}'"
        result += " with the specified filters." if environment.present? || release.present?
        return result
      end

      result = "## Recent Transactions: #{endpoint}\n\n"
      result += "**Showing:** #{transactions.size} transaction(s)\n"
      result += "**Time Range:** Last #{hours} hour(s)\n"
      result += "**Environment:** #{environment}\n" if environment.present?
      result += "**Release:** #{release}\n" if release.present?
      result += "\n"

      transactions.each_with_index do |txn, index|
        result += "### Transaction #{index + 1}\n"
        result += "**ID:** ##{txn.id}\n"
        result += "**Duration:** #{txn.duration.round}ms"
        result += " (DB: #{txn.db_time.round}ms)" if txn.db_time
        result += " (View: #{txn.view_time.round}ms)" if txn.view_time
        result += "\n"
        result += "**Timestamp:** #{txn.timestamp.strftime("%Y-%m-%d %H:%M:%S")}\n"
        result += "**HTTP:** #{txn.http_method} #{txn.http_status}\n" if txn.http_method || txn.http_status
        result += "**Environment:** #{txn.environment}\n" if txn.environment
        result += "**Release:** #{txn.release}\n" if txn.release
        result += "**Server:** #{txn.server_name}\n" if txn.server_name
        result += "**Project:** #{txn.project.name}\n"
        result += "\n"
      end

      result
    end

    def format_performance_comparison(endpoint, comparison_type, before_label, after_label,
      before_transactions, after_transactions)
      result = "## Performance Comparison: #{endpoint}\n\n"
      result += "**Comparison Type:** #{comparison_type}\n"
      result += "**Before Period:** #{before_label}\n"
      result += "**After Period:** #{after_label}\n\n"

      # before_transactions / after_transactions are already sorted Arrays of
      # durations (see durations_for in the controller).
      before_durations = before_transactions
      after_durations = after_transactions
      before_count = before_durations.size
      after_count = after_durations.size

      before_stats = calculate_percentiles(before_durations)
      after_stats = calculate_percentiles(after_durations)

      if before_stats.empty? && after_stats.empty?
        return "No transaction data available for comparison."
      end

      # Summary table
      result += "### Performance Summary\n\n"
      result += "| Metric | Before | After | Change |\n"
      result += "|--------|--------|-------|--------|\n"
      result += "| **Requests** | #{before_count} | #{after_count} | #{format_count_change(before_count, after_count)} |\n"

      if before_stats[:avg] && after_stats[:avg]
        avg_change = format_percentage_change(before_stats[:avg], after_stats[:avg])
        result += "| **Avg Duration** | #{before_stats[:avg].round}ms | #{after_stats[:avg].round}ms | #{avg_change} |\n"
      end

      if before_stats[:p50] && after_stats[:p50]
        p50_change = format_percentage_change(before_stats[:p50], after_stats[:p50])
        result += "| **Median (P50)** | #{before_stats[:p50].round}ms | #{after_stats[:p50].round}ms | #{p50_change} |\n"
      end

      if before_stats[:p95] && after_stats[:p95]
        p95_change = format_percentage_change(before_stats[:p95], after_stats[:p95])
        result += "| **P95** | #{before_stats[:p95].round}ms | #{after_stats[:p95].round}ms | #{p95_change} |\n"
      end

      if before_stats[:p99] && after_stats[:p99]
        p99_change = format_percentage_change(before_stats[:p99], after_stats[:p99])
        result += "| **P99** | #{before_stats[:p99].round}ms | #{after_stats[:p99].round}ms | #{p99_change} |\n"
      end

      # Analysis
      result += "\n### Analysis\n\n"
      if before_stats[:avg] && after_stats[:avg]
        if after_stats[:avg] < before_stats[:avg]
          improvement = ((before_stats[:avg] - after_stats[:avg]) / before_stats[:avg] * 100).round(1)
          result += "✅ **Performance improved by #{improvement}%** (average duration decreased)\n\n"
        else
          degradation = ((after_stats[:avg] - before_stats[:avg]) / before_stats[:avg] * 100).round(1)
          result += "⚠️ **Performance degraded by #{degradation}%** (average duration increased)\n\n"
        end
      end

      # before_transactions/after_transactions are sorted ascending arrays of
      # raw durations (see durations_for) — last element is the slowest.
      if before_transactions.any?
        result += "**Slowest request (before):** #{before_transactions.last.round}ms\n"
      end

      if after_transactions.any?
        result += "**Slowest request (after):** #{after_transactions.last.round}ms\n"
      end

      result
    end

    def format_percentage_change(before, after)
      return "N/A" if before.nil? || after.nil? || before == 0

      change = ((after - before) / before * 100).round(1)
      if change > 0
        "+#{change}%"
      else
        "#{change}%"
      end
    end

    def format_count_change(before, after)
      if after == before
        "No change"
      elsif after > before
        "+#{after - before} (#{((after - before).to_f / before * 100).round(1)}%)"
      else
        "#{after - before} (#{((after - before).to_f / before * 100).round(1)}%)"
      end
    end
  end
end
