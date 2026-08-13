# frozen_string_literal: true

# Builds the MCP::Server that Mcp::McpController hands each request to.
#
# Built per request rather than once at boot, because the tool schemas aren't
# static: every hours argument advertises the live retention ceiling read off
# Setting (see SplatMcpTools.hours_description), so a schema frozen at boot would
# start lying the moment retention was changed in the UI. Construction is a few
# hundred hash literals — cheap next to the queries the tools then run.
class SplatMcpServer
  # Tools that change something. Everything else is a read, and gets
  # readOnlyHint so a client can tell the difference without parsing prose —
  # the whole point of annotations, and something the hand-rolled server had no
  # way to express.
  WRITE_TOOLS = %w[resolve_issue ignore_issue reopen_issue].freeze

  # Optional per-tool project filter. MCP credentials are instance-wide (see
  # mcp_auth_outcome — there is no per-project token), so listing tools span
  # every project by default and label each row with its project name. This
  # narrows a single call without changing that default.
  PROJECT_ARG = {
    # integer as well as string: the description offers "its numeric id", and
    # resolve_project_id `to_s`es whatever arrives, so a bare 3 has always worked.
    type: ["string", "integer"],
    description: "Restrict results to one project, given as its slug, its display name, or its numeric id. Omit to cover every project on this instance."
  }.freeze

  # Absolute window bounds, spliced into every tool that takes an hours
  # argument. Without these the hours argument is a look-back from now, and a
  # past incident can only be reached if a deploy happens to bracket it.
  WINDOW_ARGS = {
    start_time: {
      type: "string",
      description: "ISO 8601 start of the window, e.g. '2026-07-14T02:00:00Z'. With the hours argument but no end_time, the window runs forward from here."
    },
    end_time: {
      type: "string",
      description: "ISO 8601 end of the window. Give this with the hours argument to look back from a past moment instead of from now — 'the 12 hours before 2026-07-14T14:00:00Z' — which is usually what you want when investigating an incident. Give both start_time and end_time for a fully explicit window; the hours argument is then ignored."
    }
  }.freeze

  # Environment/release filters for the issue tools. Both mean "seen in" — an
  # issue groups events across environments and releases, so this matches an
  # issue with at least one event carrying the value, not an issue that
  # belongs exclusively to it.
  ENVIRONMENT_ARG = {
    type: "string",
    description: "Restrict to issues seen at least once in this environment (e.g. 'production', 'staging'). Grouping spans environments, so an issue can match several."
  }.freeze

  RELEASE_ARG = {
    type: "string",
    description: "Restrict to issues seen at least once in this release version. Grouping spans releases, so an issue can match several."
  }.freeze

  # Every numeric argument is read through `&.to_i` and then clamped, so a JSON
  # string of digits has always worked exactly as well as a JSON number — and
  # clients do send "20" where the schema says integer. Now that arguments are
  # validated against these schemas, the schema has to say so, or a call that
  # always worked starts coming back as a tool error.
  #
  # `pattern` constrains only the string branch (it is a no-op on numbers).
  # json_schemer compiles it as a Ruby Regexp, where `$` also matches before a
  # newline, so "12\nx" slips through — immaterial, since `.to_i` reads the
  # leading digits and the clamp bounds the result. What it does catch is
  # "twenty", which used to pass silently and land on the minimum.
  #
  # No minimum/maximum: every reader clamps to its own range, so an
  # out-of-range limit is already handled, and rejecting it here would fail a
  # call that currently succeeds.
  def self.integer_arg(description, default: nil)
    arg = {
      type: ["integer", "string"],
      pattern: "^[0-9]+$",
      description: description
    }
    arg[:default] = default if default
    arg
  end

  # Parallelising independent reads is normally the right instinct, and here
  # it is actively dangerous: Splat is one Puma process with a small thread
  # pool, and SQLite offers no statement timeout — busy_timeout only bounds
  # lock waits, not a scan already underway. A client-side timeout doesn't
  # cancel the query either, so abandoning a slow call leaves it holding a
  # thread. Enough concurrent wide scans and the instance stops serving,
  # including the UI. Stated here because it's a property of the backend that
  # no individual tool schema can express.
  #
  # Note this reaches the client only from protocol version 2025-03-26 on —
  # `instructions` didn't exist before that, and the gem drops it when a client
  # negotiates 2024-11-05. The old hand-rolled server sent it regardless, which
  # worked only because clients were lenient about a field their own version
  # hadn't defined.
  def self.concurrency_note
    threads = ENV.fetch("RAILS_MAX_THREADS", "5")
    "Issue calls to this server SERIALLY, not in parallel. It runs a single " \
    "Puma process with #{threads} threads against SQLite, and a wide scan " \
    "(search_slow_transactions with tags, search_logs over a long window) can " \
    "hold its thread for minutes. There is no server-side statement timeout, " \
    "and giving up client-side does not cancel the query — so parallel calls " \
    "can take the whole instance down, UI included, and keep it down after " \
    "you stop. Narrow the window or add filters instead of fanning out."
  end

  def self.build
    tools = SplatMcpTools.new

    server = ::MCP::Server.new(
      name: "splat",
      title: "Splat",
      version: Splat::VERSION,
      instructions: concurrency_note,
      configuration: ::MCP::Configuration.new(
        # On, now that the schemas describe what the tools actually accept
        # (see integer_arg). A failure comes back as a tool error carrying
        # json_schemer's message, not a JSON-RPC error, so the model reads
        # "value at `/status` is not one of: [...]" and corrects itself —
        # where before, a bad enum value was quietly dropped and the result
        # silently answered a different question.
        validate_tool_call_arguments: true,

        # Only bites on tools that declare an outputSchema, and only on
        # success. On outside production so schema drift fails loudly in CI;
        # off in production because a validation error is raised, not
        # returned — a nit in the structured copy would cost the caller the
        # markdown answer as well.
        validate_tool_call_results: !Rails.env.production?
      )
    )

    tool_definitions.each do |definition|
      name = definition[:name]

      server.define_tool(
        name: name,
        description: definition[:description],
        input_schema: definition[:inputSchema],
        output_schema: output_schemas[name],
        annotations: annotations_for(name)
        # define_tool installs this as a singleton method on an anonymous Tool
        # subclass, so `self` inside is that class, not SplatMcpServer — hence the
        # explicit receiver. Locals (tools, name) still close over normally.
      ) do |server_context: nil, **args|
        SplatMcpServer.dispatch(tools, name, args)
      end
    end

    server
  end

  # The gem hands tools symbol keys all the way down (its transports parse with
  # symbolize_names), while every tool method here reads string keys — including
  # nested ones, e.g. the tags hash on search_slow_transactions. So the
  # conversion has to be deep, not a top-level transform_keys.
  #
  # ProjectResolutionError and WindowError are caught here rather than left to
  # the gem: uncaught, the gem wraps any exception as JSON-RPC -32603 with the
  # message buried under "Internal error calling tool X", which is both the wrong
  # code and the wrong audience. These are arguments the model can fix, so they
  # come back as tool errors carrying the original, actionable text.
  def self.dispatch(tools, name, args)
    tools.public_send(name, args.deep_stringify_keys)
  rescue SplatMcpTools::ProjectResolutionError, SplatMcpTools::WindowError => e
    tools.render_error(e.message)
  rescue ActiveRecord::RecordNotFound => e
    tools.render_error(e.message)
  end

  def self.annotations_for(name)
    if WRITE_TOOLS.include?(name)
      # Reversible: each just moves an issue between statuses, and the other two
      # tools put it back.
      {read_only_hint: false, destructive_hint: false, idempotent_hint: true}
    else
      {read_only_hint: true, destructive_hint: false, idempotent_hint: true}
    end
  end

  # ---- Output schemas. ----
  #
  # Only a handful of tools declare one, and that is deliberate. The markdown a
  # tool returns is not a rendering of some underlying record — it is the
  # answer, carrying units, retention caveats and read-this-way notes that no
  # schema can express ("×12, identical — memoisation, not eager loading"). A
  # structured copy earns its tokens only where the output is genuinely a
  # table or a series a caller might sort, chart or feed back in as an
  # argument. For get_event or get_transaction_spans it would just be the
  # markdown again in braces, at roughly twice the size.
  #
  # The markdown stays the `content` block; structuredContent is additive.
  # (The spec's SHOULD about also emitting the serialized JSON as text is
  # declined on purpose — that text would displace the better answer.)
  #
  # Schemas are permissive by design: every field optional, nothing forbidden.
  # A structured payload is a convenience, and it should never be the reason a
  # call fails — see validate_tool_call_results in build.
  TIMESTAMP = {type: ["string", "null"], format: "date-time"}.freeze
  MS = {type: ["number", "null"], description: "Milliseconds"}.freeze

  # start/end are the window actually used, after retention clamping — not
  # what was asked for. `label` is the same phrasing the markdown header uses.
  WINDOW_OUT = {
    type: "object",
    properties: {start: TIMESTAMP, end: TIMESTAMP, label: {type: ["string", "null"]}}
  }.freeze

  def self.output_schemas
    @output_schemas ||= begin
      issue = {
        type: "object",
        properties: {
          id: {type: "integer"},
          title: {type: ["string", "null"]},
          exception_type: {type: ["string", "null"]},
          status: {type: "string", enum: ["open", "resolved", "ignored"]},
          count: {type: "integer", description: "Occurrences recorded for this issue"},
          first_seen: TIMESTAMP,
          last_seen: TIMESTAMP,
          project: {type: ["string", "null"]}
        }
      }

      issue_list = {type: "object", properties: {issues: {type: "array", items: issue}}}

      {
        "list_recent_issues" => issue_list,
        "search_issues" => issue_list,

        "list_monitors" => {
          type: "object",
          properties: {
            monitors: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  slug: {type: "string"},
                  state: {type: "string", enum: ["ok", "missed", "error", "overrun", "unknown"]},
                  project: {type: ["string", "null"]},
                  schedule: {type: ["string", "null"]},
                  checkin_margin_minutes: {type: ["integer", "null"]},
                  max_runtime_minutes: {type: ["integer", "null"]},
                  last_checkin_at: TIMESTAMP,
                  last_status: {type: ["string", "null"]},
                  last_duration_seconds: {type: ["number", "null"]},
                  in_progress_since: TIMESTAMP,
                  environment: {type: ["string", "null"]}
                }
              }
            }
          }
        },

        "get_transaction_stats" => {
          type: "object",
          properties: {
            window: WINDOW_OUT,
            endpoint: {type: ["string", "null"], description: "Set only when the percentiles were narrowed to one endpoint"},
            environment: {type: ["string", "null"]},
            total_count: {type: "integer"},
            percentiles: {
              type: "object",
              properties: {avg: MS, p50: MS, p95: MS, p99: MS, min: MS, max: MS}
            },
            top_endpoints: {
              type: "array",
              description: "Ranked by time_spent (avg × count), never narrowed by the endpoint filter",
              items: {
                type: "object",
                properties: {
                  transaction_name: {type: ["string", "null"]},
                  time_spent: MS,
                  avg_duration: MS,
                  p95_duration: MS,
                  count: {type: "integer"}
                }
              }
            }
          }
        },

        "find_n_plus_one_endpoints" => {
          type: "object",
          properties: {
            window: WINDOW_OUT,
            environment: {type: ["string", "null"]},
            endpoints: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  transaction_name: {type: ["string", "null"]},
                  n_plus_one_count: {type: "integer"},
                  total_count: {type: "integer"},
                  n_plus_one_pct: {type: ["number", "null"]},
                  avg_queries: {type: ["number", "null"]},
                  max_queries: {type: ["integer", "null"]},
                  avg_duration: MS,
                  p95_duration: MS
                }
              }
            }
          }
        },

        "get_endpoint_timeseries" => {
          type: "object",
          properties: {
            endpoint: {type: ["string", "null"]},
            window: WINDOW_OUT,
            environment: {type: ["string", "null"]},
            release: {type: ["string", "null"]},
            bucket_seconds: {type: "integer", description: "Effective bucket width; may exceed what was requested"},
            buckets: {type: "integer"},
            requested_buckets: {type: "integer"},
            series: {
              type: "array",
              description: "Zero-filled — a bucket with no traffic is present with count 0",
              items: {
                type: "object",
                properties: {
                  bucket_start: TIMESTAMP,
                  count: {type: "integer"},
                  p50: MS,
                  p95: MS,
                  p99: MS
                }
              }
            }
          }
        }
      }.freeze
    end
  end

  # Tool definitions
  def self.tool_definitions
    [
      {
        name: "get_status",
        description: "Report this Splat instance's running version and environment, its storage breakdown (rows + bytes per table, including the legacy spans vs new span_trees split), the data span / retention window per data table (oldest + newest row for events, transactions, span_trees, logs, and the histogram/hourly_stats tables the performance sparklines read — this answers 'how many days of data/spark do we actually keep?'), and payload-compression ratios/savings. Use it to confirm which version is deployed, how far back data goes, and whether compression is working. The version is live; storage/retention/compression come from a snapshot refreshed every ~15 min (collected_at is included).",
        inputSchema: {
          type: "object",
          properties: {}
        }
      },
      {
        name: "list_monitors",
        description: "List check-in monitors (Sentry Crons / dead-man's-switch heartbeats): each monitor's slug, evaluated state (ok / missed / error / overrun / unknown), schedule, margin, last check-in time + status, last duration, and environment. Monitors auto-register from check-in envelopes; a missed/error/overrun state means an Issue is (or is about to be) open for it — find it by fingerprint monitor:<slug>:<kind> via search_issues.",
        inputSchema: {
          type: "object",
          properties: {
            state: {
              type: "string",
              description: "Filter by evaluated state (default: all)",
              # Derived, not restated: an enum the validator enforces has to
              # track the model, or adding a state silently starts rejecting it.
              enum: CronMonitor::STATES
            },
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "list_recent_issues",
        description: "List the most recent issues, optionally filtered by status, environment or release",
        inputSchema: {
          type: "object",
          properties: {
            status: {
              type: "string",
              description: "Filter by status: 'open', 'resolved', 'ignored', or 'all' (default: 'open')",
              enum: Issue.statuses.keys + ["all"]
            },
            limit: integer_arg("Maximum number of results (default: 20, max: 100)", default: 20),
            environment: ENVIRONMENT_ARG,
            release: RELEASE_ARG,
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "search_issues",
        description: "Search for issues by keyword, status, exception type, environment or release",
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
              enum: Issue.statuses.keys
            },
            exception_type: {
              type: "string",
              description: "Filter by specific exception type"
            },
            limit: integer_arg("Maximum results (default: 20, max: 100)", default: 20),
            environment: ENVIRONMENT_ARG,
            release: RELEASE_ARG,
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "get_issue",
        description: "Get detailed information about a specific issue by ID",
        inputSchema: {
          type: "object",
          properties: {
            issue_id: integer_arg("The ID of the issue")
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
            issue_id: integer_arg("The ID of the issue"),
            limit: integer_arg("Maximum events to return (default: 10, max: 50)", default: 10)
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
              description: "Filter the overall percentile block to one endpoint (e.g., 'AlertsController#index'). The top-endpoints list is never narrowed by this — it always covers whatever the project filter allows."
            },
            time_range_hours: integer_arg(SplatMcpTools.hours_description(:rollup), default: 24),
            **WINDOW_ARGS,
            limit: integer_arg("Maximum number of top endpoints to return (default: 10, max: 50)", default: 10),
            environment: {
              type: "string",
              description: "Restrict every figure — percentiles, count and the top-endpoints list — to one environment (e.g. 'staging')."
            },
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "find_n_plus_one_endpoints",
        description: "List endpoints where transactions show N+1 query patterns (the same SQL pattern repeated >3 times in one request). Ranked by number of affected transactions. Returns N+1 count, total count, % affected, avg/max queries per request, and avg/p95 duration. Use this to find endpoints that need eager-loading or query consolidation.",
        inputSchema: {
          type: "object",
          properties: {
            time_range_hours: integer_arg(SplatMcpTools.hours_description(:rollup), default: 24),
            **WINDOW_ARGS,
            environment: {
              type: "string",
              description: "Filter by environment (optional)"
            },
            limit: integer_arg("Maximum endpoints to return (default: 20, max: 100)", default: 20),
            project: PROJECT_ARG
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
            hours: integer_arg(SplatMcpTools.hours_description(:rollup, "Time range in hours") + ". A release filter restricts it to #{SplatMcpTools.max_hours(:transactions)}h, since release isn't carried on the rollups.", default: 24),
            **WINDOW_ARGS,
            buckets: integer_arg("Number of buckets to split the range into (default: 24 → 1-hour buckets for a 24h range; min: 4, max: 168). Buckets an hour or wider are widened to a whole number of hours so the series can be served from the hourly rollups, so the count returned may be slightly lower than requested — the response states the effective width.", default: 24),
            environment: {
              type: "string",
              description: "Filter by environment (optional)"
            },
            release: {
              type: "string",
              description: "Filter by application version/release (optional)"
            },
            project: PROJECT_ARG
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
            min_duration_ms: integer_arg("Minimum duration in milliseconds (default: 1000)", default: 1000),
            max_duration_ms: integer_arg("Optional upper bound, making the duration filter a band. Results are ordered slowest-first, so over a wide window a few multi-minute outliers crowd out everything else — pair this with min_duration_ms (e.g. 10000..20000) to surface a plateau of merely-slow requests that would otherwise never reach the page."),
            endpoint: {
              type: "string",
              description: "Filter by endpoint name (case-insensitive substring match, e.g. 'works' matches 'WorksController#show')"
            },
            http_status: {
              type: ["string", "integer"],
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
            release: {
              type: "string",
              description: "Filter to one release (e.g. '1.12.0'). Indexed, unlike a tag filter. Every window here is measured back from now, so when a deploy brackets the period you care about this is the way to pin results to it."
            },
            time_range_hours: integer_arg(SplatMcpTools.hours_description(:transactions), default: 24),
            **WINDOW_ARGS,
            limit: integer_arg("Maximum results (default: 20, max: 100)", default: 20),
            tags: {
              type: "object",
              description: "Filter by Sentry tags. Keys are AND'd; string equality. " \
                           "Example: {\"user_id\":\"123\",\"environment\":\"production\"}. " \
                           "NOTE: tags are unindexed JSON, so this scans every transaction in the " \
                           "window and holds a thread until it finishes — prefer release, endpoint " \
                           "or environment to narrow first, and keep the window tight.",
              # Values are `to_s`'d before they reach the query, so a number or
              # boolean is as good as a string — and a model filtering on
              # user_id naturally writes it as a number. Only the keys are
              # constrained (to the tag-name charset), and that check lives in
              # the tool, which can explain itself better than a schema can.
              additionalProperties: {type: ["string", "integer", "number", "boolean"]}
            },
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "get_transaction",
        description: "Get detailed information about a specific transaction, by transaction ID or by trace_id. The trace_id form closes the loop from a log line to the request that produced it: search_logs and get_trace_logs hand back trace IDs, and this turns one into the transaction (then get_transaction_spans for its waterfall).",
        inputSchema: {
          type: "object",
          properties: {
            transaction_id: {
              type: ["string", "integer"],
              description: "Either the internal numeric ID (e.g. '12345') or the Sentry transaction UUID (32 hex chars, e.g. 'abc123...'). UUIDs match the event_id used by get_event."
            },
            trace_id: {
              type: "string",
              description: "Look the transaction up by trace_id instead — the value carried on log records and accepted by get_trace_logs. Supply this or transaction_id. Passing `project` alongside it makes the lookup an index hit."
            },
            project: PROJECT_ARG
          }
        }
      },
      {
        name: "get_transaction_spans",
        description: "Get the per-span waterfall for a single transaction. Each span is one timed operation inside the request — a SQL query, an outbound HTTP call, a view render, a cache hit. Span descriptions retain table and column names (e.g. `SELECT \"covers\".* FROM \"covers\" WHERE \"covers\".\"id\" = ?`), unlike the aggregated query_patterns on get_transaction where identifiers are also stripped. Use this when get_transaction shows N+1 patterns but you can't tell which association is firing — span descriptions disambiguate. Returns: op summary (count + total time per op type), repeated descriptions (the classic N+1 fingerprint), and a depth-indented span list.",
        inputSchema: {
          type: "object",
          properties: {
            transaction_id: {
              type: ["string", "integer"],
              description: "Either the internal numeric ID or the Sentry transaction UUID — same value accepted by get_transaction."
            },
            trace_id: {
              type: "string",
              description: "Look the transaction up by trace_id instead, so a log line can be taken straight to its span waterfall. Supply this or transaction_id."
            },
            project: PROJECT_ARG,
            op_filter: {
              type: "string",
              description: "Filter spans by op prefix (e.g. 'db' for all db.* spans, 'db.sql' for SQL only, 'http' for outbound HTTP, 'view' for renders). Default: no filter."
            },
            limit: integer_arg("Max spans to render in the list (default: 100, max: 1000). Op summary and repeated-description sections always cover all spans.", default: 100)
          }
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
            hours: integer_arg(SplatMcpTools.hours_description(:rollup, "Time range in hours") + ". A release filter restricts it to #{SplatMcpTools.max_hours(:transactions)}h, since release isn't carried on the rollups.", default: 24),
            **WINDOW_ARGS,
            environment: {
              type: "string",
              description: "Filter by environment (optional)"
            },
            release: {
              type: "string",
              description: "Filter by application version/release (optional)"
            },
            project: PROJECT_ARG
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
            limit: integer_arg("Number of results (default: 20, max: 100)", default: 20),
            hours: integer_arg(SplatMcpTools.hours_description(:transactions, "Time range in hours"), default: 24),
            **WINDOW_ARGS,
            environment: {
              type: "string",
              description: "Filter by environment (optional)"
            },
            release: {
              type: "string",
              description: "Filter by application version/release (optional)"
            },
            project: PROJECT_ARG
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
            hours_before: integer_arg(SplatMcpTools.hours_description(:transactions, "Hours before comparison point"), default: 24),
            hours_after: integer_arg(SplatMcpTools.hours_description(:transactions, "Hours after comparison point"), default: 24),
            environment: {
              type: "string",
              description: "Filter by environment (optional)"
            },
            project: PROJECT_ARG
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
            issue_id: integer_arg("The ID of the issue to resolve")
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
            issue_id: integer_arg("The ID of the issue to ignore")
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
            issue_id: integer_arg("The ID of the issue to reopen")
          },
          required: ["issue_id"]
        }
      },
      {
        name: "search_logs",
        description: "Search structured logs (from Sentry Logs or OTLP) by level, logger, trace, environment, or full-text query over the message and attributes. Covers every project on this instance unless you pass `project`; results are prefixed with the project name.",
        inputSchema: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Full-text query over the log message body and its attributes. Whole-word tokens, not substrings: 'timeout' matches 'timeout' but not 'timeouts'. Multiple words are ANDed. Use key:value (e.g. method:POST, dbname:booko_production) to match an attribute. Note that fractional values such as durations are not indexed and cannot be searched."
            },
            level: {
              type: "string",
              description: "Filter by severity level",
              enum: Log.levels.keys
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
            release: {
              type: "string",
              description: "Filter to one release (e.g. '1.12.0'). Indexed, unlike a tag filter — use it to scope logs to a single deploy."
            },
            time_range_hours: integer_arg(SplatMcpTools.hours_description(:logs, "Look back this many hours"), default: 24),
            **WINDOW_ARGS,
            limit: integer_arg("Maximum results (default: 50, max: 200)", default: 50),
            project: PROJECT_ARG
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
            limit: integer_arg("Maximum results (default: 100, max: 500)", default: 100)
          },
          required: ["trace_id"]
        }
      }
    ]
  end
end
