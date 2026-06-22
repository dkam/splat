Use use the oauth


# Splat - Lightweight Error Tracker & APM

Splat is a simple error tracker and lightweight backend APM. It's a fast, reliable alternative to Sentry for applications that need error monitoring and performance insight without the overhead.

Splat supports OIDC but defaults to no authentication. It has an MCP endpoint for your LLM Agents to use. This app was Agentically Engineered, partnering with GLM / Sonnet / Opus. 

Initially built as an experiment in using SQLite in a write-heavy service, it's performed well enough for my use case, growing into a capable error tracker, a focused backend APM, and a structured log store — exception grouping plus transaction tracing, span waterfalls, latency percentiles, N+1 detection, and full-text searchable logs that tie back to traces, all queryable by an LLM over MCP.

I've only used Splat with Rails, but there's no reason it shouldn't work with other systems. Happy to accept pull requests for wider compatibility.

If you're looking for other Sentry clones, take a look at Glitchtip, Bugsink & Telebugs. 

## Overview

**Named after Ruby's splat operator and the satisfying sound of squashing bugs**, Splat accepts Sentry-compatible error events and transaction data via a simple API endpoint, processes them asynchronously, and presents them in a clean, fast web interface.

### Key Features

**Error Tracking**
- ✅ **Fingerprint Grouping** - Groups events into issues by Sentry fingerprint, or derives one from exception type + location
- ✅ **Issue Lifecycle** - Open / resolved / ignored, with resolved issues auto-reopening on new events
- ✅ **Fast Ingestion** - Errors appear in the UI within seconds
- ✅ **Stack Traces & Context** - Full event detail: stack trace, request data, breadcrumbs, user context
- ✅ **Burst Alerting** - Spike detection with a configurable threshold, plus email and [ntfy.sh](https://ntfy.sh) notifications on new and reopened issues
- ✅ **Release Tracking** - Stamps issues with first/last seen release, overlays deploy markers on issue sparklines so regressions are visible at a glance

**Performance Monitoring**
- ✅ **Transaction Tracing** - Request timings with db_time / view_time breakdown
- ✅ **Span Waterfall** - Per-transaction span tree rendered as a tiered timeline on the transaction detail page
- ✅ **Latency Percentiles** - p50 / p95 / p99 via DDSketch histograms (±1% error), not naive array indexing
- ✅ **Endpoint Impact Ranking** - Surfaces controllers ranked by total time spent (avg × count) plus p95, so you optimise where it actually pays back
- ✅ **N+1 Query Detection** - Mines `measurements.query_analysis` from the transaction span analyzer, ranks endpoints by N+1 prevalence, exposes a dedicated worklist and an MCP tool
- ✅ **Trends & Comparison** - Hourly pre-aggregates power time-series charts and release-over-release endpoint comparison

**Logs**
- ✅ **Structured Log Ingestion** - Accepts both Sentry Logs (envelope item type `log`) and OpenTelemetry over OTLP/HTTP (`POST /v1/logs`), normalized into one searchable shape
- ✅ **Full-Text Search** - SQLite FTS5 over message body *and* flattened attributes, with a `key:value` shorthand (e.g. `status:422 method:POST timeout`)
- ✅ **Trace Correlation** - Logs carry `trace_id`, so a log links to its transaction and a transaction links back to its logs (sampling-aware — the link only appears when the other side exists)
- ✅ **zstd Dictionary Compression** - The full record (including attributes) is compressed into a blob with a trained zstd dictionary; hot query/display fields are promoted to columns
- ✅ **Level & Environment Facets** - Filter by severity (Sentry trace→fatal or bucketed OTLP severity numbers) and environment

**Platform**
- ✅ **Sentry Protocol Compatible** - Drop-in replacement for Sentry client SDKs
- ✅ **MCP Integration** - Query errors and performance data via Claude and other AI assistants
- ✅ **Single-Tenant Design** - Simple setup, no user management overhead
- ✅ **Minimal Dependencies** - Rails + SQLite + Solid Queue
- ✅ **Auto-Cleanup** - Configurable data retention (default 90 days)

### Why Splat?
When you need error tracking that:
- Your code assistant can grab issues and stack traces from
- Shows errors within seconds
- Can be understood and modified in one sitting
- Latest Rails / Ruby on an all-SQLite stack plus the Solid trio (Queue/Cache/Cable). The running versions are shown on the Settings page.


## Screenshots

### 1. Projects Dashboard
[![Projects Dashboard](docs/screenshots/thumbs/1-projects.png)](docs/screenshots/1-projects.png)

### 2. Project Detail View
[![Project Detail](docs/screenshots/thumbs/2-project.png)](docs/screenshots/2-project.png)

### 3. Issues List
[![Issues List](docs/screenshots/thumbs/3-issues.png)](docs/screenshots/3-issues.png)

### 4. Issue Detail with Stack Trace
[![Issue Detail](docs/screenshots/thumbs/4-issue.png)](docs/screenshots/4-issue.png)

### 5. Event Details
[![Event Details](docs/screenshots/thumbs/5-event.png)](docs/screenshots/5-event.png)

### 6. Performance Monitoring
[![Performance Monitoring](docs/screenshots/thumbs/6-performance.png)](docs/screenshots/6-performance.png)

## Getting Started

### Prerequisites
- Ruby (latest — see `.ruby-version`)
- Rails (latest)
- SQLite3

### Installation
```bash
git clone <repository-url>
cd splat
bundle install
bin/rails db:prepare
bin/dev
```

### Configuration

#### Email Notifications
Configure SMTP settings for email notifications when issues are created or reopened:

```bash
# Required settings
SMTP_ADDRESS=smtp.gmail.com
SMTP_PORT=587
SMTP_USER_NAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password

# Optional settings (with defaults shown)
SMTP_DOMAIN=localhost
SMTP_AUTHENTICATION=plain
SMTP_STARTTLS_AUTO=true
SPLAT_HOST=splat.example.com
SPLAT_INTERNAL_HOST=100.x.x.x:3030  # Your Tailscale IP maybe? Used for displaying alternate DSN

# For local development with self-signed certificates, use:
SMTP_OPENSSL_VERIFY_MODE=none

# Email recipients
SPLAT_ADMIN_EMAILS=admin@example.com,dev-team@example.com
SPLAT_EMAIL_FROM=noreply@splat.com
```

#### Email Notification Control
```bash
# Enable email notifications in development
SPLAT_EMAIL_NOTIFICATIONS=true

# In production, emails are sent by default
```

## Deployment

### Docker Compose

```yaml
x-common-variables: &common-variables
  RAILS_ENV: production
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
  SPLAT_HOST: ${SPLAT_HOST}
  SPLAT_ADMIN_EMAILS: ${SPLAT_ADMIN_EMAILS}
  SPLAT_EMAIL_FROM: ${SPLAT_EMAIL_FROM}

  SMTP_ADDRESS: ${SMTP_ADDRESS}
  SMTP_PORT: ${SMTP_PORT}
  SMTP_USER_NAME: ${SMTP_USER_NAME}
  SMTP_PASSWORD: ${SMTP_PASSWORD}

  # MCP Authentication Token
  MCP_AUTH_TOKEN: ${MCP_AUTH_TOKEN}

  # Splat reports its own errors/traces to a Sentry-compatible DSN (often itself).
  SENTRY_DSN: ${SENTRY_DSN}
  SENTRY_TRACES_SAMPLE_RATE: ${SENTRY_TRACES_SAMPLE_RATE}

  # Token shared with any upstream Splat that forwards envelopes to this one.
  SPLAT_FORWARDER_TOKEN: ${SPLAT_FORWARDER_TOKEN}

  # Send Rails logs to stdout so `docker compose logs <service>` works without
  # fiddling with bind-mount permissions on log/production.log.
  RAILS_LOG_TO_STDOUT: "true"

  # Tuber work queue — ingestion is enqueued here. Container-to-container DNS
  # uses the service name on the container port (11300); the host-side 11330
  # mapping below is irrelevant inside the compose network.
  TUBER_URL: tuber:11300

# Shared config for the non-web Rails containers (worker + scheduler). They run
# the same image as web with a different command and no published ports.
x-splat-worker: &splat-worker
  image: ghcr.io/dkam/splat:latest
  pull_policy: always
  restart: unless-stopped
  depends_on:
    - tuber
  volumes:
    - /storage/splat/storage:/rails/storage
  environment:
    <<: *common-variables
  logging:
    driver: "json-file"
    options:
      max-size: "100m"
      max-file: "3"

services:
  # HTTP server: ingest API, MCP endpoint, and the UI.
  web:
    image: ghcr.io/dkam/splat:latest
    pull_policy: always   # :latest moves on each release; always re-pull on `up -d`
    environment:
      <<: *common-variables
      # OIDC is only needed by the web tier (see Authentication below).
      OIDC_CLIENT_ID: ${OIDC_CLIENT_ID}
      OIDC_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      OIDC_DISCOVERY_URL: ${OIDC_DISCOVERY_URL}
      OIDC_PROVIDER_NAME: ${OIDC_PROVIDER_NAME}
      OIDC_REQUIRE_PKCE: ${OIDC_REQUIRE_PKCE}
      SPLAT_ALLOWED_USERS: ${SPLAT_ALLOWED_USERS}
    volumes:
      - /storage/splat/storage:/rails/storage
      - /storage/splat/logs/web:/rails/log
    ports:
      - "${HOST_IP}:3030:3000"
    depends_on:
      - tuber
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  # Drains the Tuber tubes: ingestion (events/transactions/spans/logs) plus the
  # maintenance tube (retention, histogram rollups, dictionary training, storage
  # stats). Safe to scale to multiple replicas.
  worker:
    <<: *splat-worker
    command: bin/ingest_worker
    volumes:
      - /storage/splat/storage:/rails/storage
      - /storage/splat/logs/worker:/rails/log
    mem_limit: 512M

  # Fires recurring jobs (config/schedule.yml) onto the maintenance tube. Run
  # exactly ONE replica — bin/scheduler has no cross-process lock, so a second
  # instance would double every cron fire.
  scheduler:
    <<: *splat-worker
    command: bin/scheduler
    volumes:
      - /storage/splat/storage:/rails/storage
      - /storage/splat/logs/scheduler:/rails/log
    mem_limit: 256M

  tuber:
    image: ghcr.io/tuberq/tuber:latest
    # The image entrypoint is the bare `tuber` binary; it needs a subcommand.
    # --migrate-wal upgrades an older binlog format in place on start.
    command: server --migrate-wal
    environment:
      - TUBER_NAME=splat
      - TUBER_LISTEN=0.0.0.0
      - TUBER_PORT=11300
      - TUBER_BINLOG_DIR=/var/lib/tuber/binlog
      - TUBER_MAX_STORAGE_BYTES=20gb
      - TUBER_MAX_JOBS_SIZE=1gb
      - TUBER_MAX_JOB_SIZE=20mb        # must fit packed batches (~5MB at 100/batch)
      - TUBER_METRICS_PORT=9100
    ports:
      - "${HOST_IP}:11330:11300"        # beanstalkd protocol
      - "${HOST_IP}:9130:9100"          # metrics (Prometheus / Uptime Kuma)
    volumes:
      - /storage/splat/storage/tuber:/var/lib/tuber/binlog
    restart: unless-stopped
    mem_limit: 1500M
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

## Authentication

1. None: Anyone can access splat - ensure it's running internal / within a VPN
2. Basic Auth: Use your webserver to implement Basic Auth, avoiding protecting /api/ and /mcp/ endpoints as they're already authenticated
3. OIDC: Set the 


### Basic Auth
Assuming a Caddy server which forwards traffic to Splat. 
The following configuration uses basic auth, but allows free access to the `/api/` and `/mcp/` endpoints.

```
splat.booko.info {
  encode zstd gzip

  # Handle /api/* and /mcp/* routes without basic auth (both use token auth)
  handle /api/* /mcp* {
    reverse_proxy * {
      to http://<ip address>:3030
    }
  }

  # Handle all other routes with basic auth
  handle {
    basicauth {
      <user> <basic-auth-hash>
    }
    reverse_proxy * {
      to http://<ip address>:3030
    }
  }

  log {
    output file /var/log/caddy/splat.log
  }
}
```

Generate the basic auth hash with `docker compose exec -it caddy caddy hash-password`


### OIDC

Splat supports OIDC
```
OIDC_CLIENT_ID=<OIDC CLIENT ID>
OIDC_CLIENT_SECRET=<OIDC CLIENT SECRET>
OIDC_DISCOVERY_URL=<OIDC DISCOVERY URL>

SPLAT_ALLOWED_USERS="Comma seperated list of email addresses allowed access Splat"
SPLAT_ALLOWED_DOMAINS="Comma seperated list of email domains allowed access Splat"

# Optional
OIDC_PROVIDER_NAME=<OIDC Providername>
OIDC_REQUIRE_PKCE=<true/false>
```

## Performance

Splat has been tested in production handling real-world traffic with excellent results.

### Production Metrics

**Sustained load: ~1,550 transactions/minute (~26 tx/s)**
- Web container: 1.07 GB RAM, ~19% CPU
- Jobs container: 340 MB RAM, ~20% CPU
- Queue depth: 0 (no backlog)
- No database locks or contention

**Total resources: ~1.4 GB RAM, ~0.8 CPU cores** for both containers combined.

**Throughput: ~2.2 million transactions/day**

### SQLite Performance

At 26 transactions/second sustained with **~950k transactions in database (4.7GB)**:
- ✅ No SQLITE_BUSY errors
- ✅ No write conflicts
- ✅ Linear CPU scaling with load
- ✅ Stable memory usage (plateaus around 1GB for web container)
- ✅ Memory remains stable as throughput increases (tested 14-26 tx/s)
- ✅ Database size has no impact on ingestion performance ( so far )

Rails 8.1's SQLite optimizations (WAL mode, connection pooling) handle write-heavy workloads efficiently.

### Storage Architecture: All SQLite

Splat stores everything — events, transactions, spans, and pre-rolled aggregates — in SQLite. There is no separate analytics engine to operate.

- **Raw rows** are the source of truth for ingestion, find-by-id lookups, status changes, and the recent-firehose views. Fast, embedded, no operational overhead.
- **Aggregates** — the time-windowed numbers behind endpoint stats, percentile breakdowns, response-time charts, the "Top Endpoints by Impact" table, and the project dashboard — are rolled up into compact summary tables (e.g. `transaction_histograms`) by a recurring job, so the dashboards stay fast even as raw rows are pruned.

Raw rows and aggregates have separate retention windows, so you can prune the high-volume raw data aggressively (days) while keeping the tiny aggregate history for much longer (months). Retention windows are configurable on the Settings page.

#### Endpoint Impact Ranking

The performance dashboard ranks endpoints by **time spent** (`avg_duration × count`) rather than average duration. A 50ms endpoint hit 10,000×/day costs more total time than a 2s endpoint hit 5×/day — sorting by impact tells you where optimisation actually pays back. The same table also surfaces P95 alongside, so a tail-heavy endpoint isn't hidden by a low average.

#### Span Storage and SQL Normalization

Each transaction's span tree is stored in SQLite and rendered as a waterfall on the transaction detail page. Spans are 10–100× the volume of transactions, so a single ingest-time normalization pass keeps storage manageable:

- **SQL normalization at ingest:** span descriptions like `SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'` are rewritten to `SELECT * FROM users WHERE id = ? AND email = ?` *before* being written to disk. The parameterized form collapses the near-infinite variety of literal-bearing queries down to a handful of distinct patterns.
- **Privacy bonus:** because literals never reach disk, user IDs, email addresses in WHERE clauses, names in INSERTs, and tokens in URL paths are automatically redacted. We can show you the *pattern* of the offending query, but not the literal values that triggered it. This is a deliberate trade-off — and a documented commitment, not an accident.
- **Cap and retention:** spans are capped at 1000 per transaction (excess dropped, transaction flagged) and retained for 30 days by default (configurable separately from transactions, since span volume is far higher).

#### N+1 Query Detection

Splat flags endpoints that issue the same query in a loop — the classic N+1 — straight from the SQL breadcrumbs a transaction carries, with no extra instrumentation in the monitored app.

**How a single transaction is judged** (`Transaction::SpanAnalyzer.analyze_sql_queries`, at ingest):

1. Pull the `sql.active_record` breadcrumbs from the payload.
2. **Drop infrastructure queries.** Cache, job-queue, cable, schema-bookkeeping, and SQLite-introspection tables (`solid_cache_entries`, `solid_queue_*`, `solid_cable_messages`, `schema_migrations`, `ar_internal_metadata`, `sqlite_*`, `dbstat`) are framework plumbing, not application work. SolidCache alone fires `get + delete + put` on every `Rails.cache.fetch` miss, so a request doing a few cache lookups would otherwise look like an N+1 of identical queries. They're excluded from both the query count and the scan so the signal reflects *your* DB work.
3. **Normalize** each remaining query to a pattern — literals collapse to `?`, IN-lists to `IN (?)`, query-log-tag comments (`/* ... */`) are stripped, but table/column identifiers are preserved so different tables stay distinct (see SQL normalization above).
4. **Group by pattern and count.** A pattern that appears **more than 3 times** in one transaction marks it as a potential N+1 (`has_n_plus_one`), and the per-transaction `query_count` is recorded.

**How it rolls up.** The hourly aggregation job folds each transaction's `has_n_plus_one` flag and query counts into `transaction_hourly_stats` per endpoint, so the dashboards stay fast and the signal survives raw-row retention. The N+1 view ranks endpoints by how many of their transactions were flagged, alongside avg/max queries per request and latency.

**Where it surfaces:**
- **Endpoints dashboard** → the dedicated "N+1" view (`/projects/:slug/endpoints/n_plus_one`).
- **Transaction detail page** → flagged patterns for a single request.
- **MCP** → the `find_n_plus_one_endpoints` tool, for asking an AI assistant "which endpoints have N+1 problems?".

**Heuristic, not a profiler.** This is a count-of-repeated-patterns signal, deliberately simple. Unlike in-process tools such as [Prosopite](https://github.com/charkost/prosopite) — which group queries by call-site from a live backtrace — Splat only has the stored SQL text, so it can't tell a genuine loop from the same query shape legitimately reached via different code paths. The `> 3` threshold and the infrastructure denylist keep false positives down; treat a flag as "worth a look," then confirm against the transaction's span waterfall.

### Structured Logs

Splat ingests structured logs alongside errors and transactions, into their own SQLite database (separate retention, separate file). Two wire formats are accepted and normalized into a single shape at ingest:

- **Sentry Logs** — envelope item type `log`, sent by the same SDK already pointed at Splat.
- **OpenTelemetry** — OTLP/HTTP, JSON-encoded, at `POST /v1/logs`. Severity numbers are bucketed onto Sentry's `trace → debug → info → warn → error → fatal` scale so both sources share one level enum.

**Compact storage.** The full record — message plus arbitrary attributes — is compressed into a blob using a trained zstd dictionary (logs are small and repetitive, so a shared dictionary pays off far more than per-row compression). The hot fields used for listing and filtering (timestamp, level, logger, environment, `trace_id`, `span_id`) are promoted to real columns and indexed; everything else is decompressed only when you open a single log.

**Full-text search.** An FTS5 index covers both the message body and the *flattened* attributes, kept in sync with the table on insert/delete. The search box accepts free text (each token ANDed) plus a `key:value` shorthand that scopes a value to its attribute — so `status:422` matches a `422` stored under `status`, not some unrelated field. Pasted UUIDs are collapsed to a single token so a hyphenated id matches the way it's indexed.

**Trace correlation.** Because logs carry `trace_id`, the log detail page links to its transaction and the transaction detail page links back to "View N logs for this trace." The two directions are deliberately lopsided: logs are ingested at ~100% while transactions are typically sampled (e.g. 1–10%), so the log→transaction link only appears when that trace happened to be sampled, while transaction→logs almost always resolves. Each link only renders when the other side actually exists, so you never land on an empty page.

## Maintenance

### Data Retention and Cleanup

Splat automatically cleans up old data to manage database size and maintain performance.

#### Default Retention Periods
- **Events/Issues**: 90 days (configurable via `SPLAT_MAX_EVENT_LIFE_DAYS`)
- **Transactions**: 90 days (configurable via `SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS`)
- **Spans**: 30 days (span volume is far higher than transactions)
- **Logs**: 14 days (configurable on the Settings page; logs are high-volume)
- **Files**: 90 days (configurable via `SPLAT_MAX_FILE_LIFE_DAYS`)

#### Cleanup Process
- **Schedule**: Daily at 2:00 AM UTC via Solid Queue recurring jobs
- **Actions**:
  - Deletes events older than retention period
  - Deletes transactions older than retention period
  - Removes empty issues (issues with no associated events)
  - Logs cleanup statistics to Rails logger

#### Configuration
Override default retention periods with environment variables:

```bash
# Keep events for 30 days instead of 90
SPLAT_MAX_EVENT_LIFE_DAYS=30

# Keep transactions for 60 days
SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS=60

# Keep files for 180 days
SPLAT_MAX_FILE_LIFE_DAYS=180
```

#### Manual Cleanup
To run cleanup manually:

```bash
# Run cleanup with default settings
bin/rails runner "CleanupEventsJob.new.perform"

# Run cleanup with custom retention periods
SPLAT_MAX_EVENT_LIFE_DAYS=30 bin/rails runner "CleanupEventsJob.new.perform"
```

#### Monitoring
Check cleanup activity in Rails logs:

```bash
tail -f log/production.log | grep "Cleanup"
```

Example log output:
```
Started cleanup: events=90d, transactions=90d, files=90d
Deleted 1,234 old events
Deleted 567 old transactions
Deleted 89 empty issues
Cleanup completed successfully
```

## Monitoring

Splat provides a `/_health` endpoint for monitoring service status and queue depth.

### Health Endpoint
```bash
GET /_health
```

Response:
```json
{
  "status": "ok",
  "timestamp": "2025-10-23T12:34:56Z",
  "queue_depth": 0,
  "queue_status": "healthy",
  "event_count": 1234,
  "issue_count": 56,
  "transaction_count": 5678,
  "transactions_per_second": 1.23,
  "transactions_per_minute": 73.5
}
```

**Response Fields:**
- `status`: Overall system health (`ok` or `degraded`)
- `queue_status`: Queue health (`healthy`, `warning`, or `critical`)
- `queue_depth`: Number of pending background jobs
- `timestamp`: Current server time (ISO 8601)
- `event_count`: Total error events tracked
- `issue_count`: Number of open issues
- `transaction_count`: Total performance transactions
- `transactions_per_second`: Rate over last minute
- `transactions_per_minute`: Rate over last hour

**Environment Variables for Thresholds:**
```bash
# Optional - defaults shown
QUEUE_WARNING_THRESHOLD=50   # queue_status becomes "warning"
QUEUE_CRITICAL_THRESHOLD=100 # queue_status becomes "critical", status becomes "degraded"
```

### Uptime Kuma Setup

**Monitor Configuration:**
- **Monitor Type**: HTTP(s) - JSON Query
- **URL**: `https://splat.yourdomain.com/_health`
- **Expected Status Code**: 200
- **Check Interval**: 60 seconds (or your preference)

**Option 1: Monitor Queue Status (Recommended)**
- **JSON Path**: `$.queue_status`
- **Expected Value**: `healthy`
- **Alert When**: Value is not equal to expected value
- **Result**: Alerts when queue is "warning" or "critical"

**Option 2: Monitor Overall Status**
- **JSON Path**: `$.status`
- **Expected Value**: `ok`
- **Alert When**: Value is not equal to expected value
- **Result**: Alerts only when system is "degraded" (critical queue depth)

**Notification Settings:**
Configure Uptime Kuma to send alerts via:
- Email
- Slack
- Discord
- Webhook
- Or any of the 90+ notification services supported

**Monitoring Guidelines:**
- **Normal queue depth**: 0-10 jobs (instant processing)
- **Warning level**: 50-99 jobs (queue building up)
- **Critical level**: 100+ jobs (queue backlog)

**When queue_status is "warning":**
- Jobs are processing but slower than ingestion rate
- Check Solid Queue worker status
- Consider scaling workers if sustained

**When queue_status is "critical":**
- Significant backlog, data delayed
- Immediate investigation needed
- Check for worker crashes or resource constraints

## Backup

Splat uses SQLite databases. Two recommended backup strategies:

**[Litestream](https://litestream.io/)** - Continuous replication to S3-compatible storage
- Real-time backup with ~10-30 second lag
- Supports AWS S3, Backblaze B2, Cloudflare R2, MinIO
- Point-in-time recovery

**[sqlite3_rsync](https://github.com/cannadayr/git/blob/master/sqlite3_rsync)** - Efficient incremental backups
- Creates byte-for-byte clones of live databases
- Works while database is in use
- Smaller incremental transfers than full copies

### What to Backup
- `storage/production.sqlite3` - Events, issues, transactions (critical)
- `storage/production_logs.sqlite3` - Structured logs (critical if you rely on them)
- `storage/production_queue.sqlite3` - Background jobs (recommended)
- `storage/production_cache.sqlite3` - Performance counters (optional)

## Model Context Protocol (MCP) Integration

Splat exposes an MCP server that allows Claude and other AI assistants to query error tracking and performance data directly. As Splat has no authentication system, we'll use an environment set value for an authentication token.

### Setup

**1. Generate an authentication token:**

```bash
# Using OpenSSL
openssl rand -hex 32

# Or using Ruby
ruby -r securerandom -e 'puts SecureRandom.hex(32)'
```

**2. Add to your environment:**

```bash
# .env
MCP_AUTH_TOKEN=your-generated-token-here
```

**3. Configure Claude Desktop:**

**Note:** Claude Desktop currently only supports `stdio` transport (not HTTP). To use Splat's MCP server with Claude Desktop, you'll need to create a proxy script.

Create a file at `~/splat-mcp-proxy.sh`:

```bash
#!/bin/bash
# Proxy for Splat MCP over stdio -> HTTP
# Replace TOKEN with your actual MCP_AUTH_TOKEN

while IFS= read -r line; do
  echo "$line" | curl -s -X POST http://localhost:3030/mcp \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer YOUR_TOKEN_HERE" \
    -d @-
done
```

Make it executable:
```bash
chmod +x ~/splat-mcp-proxy.sh
```

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "splat": {
      "command": "/Users/YOUR_USERNAME/splat-mcp-proxy.sh",
      "transport": {
        "type": "stdio"
      }
    }
  }
}
```

**Alternative: Use from Claude Code (supports HTTP):**

You can use command line like: 

`claude mcp add --transport http splat http://localhost:3030/mcp --header "Authorization: Bearer your-generated-token-here"

Claude Code (VS Code extension) supports HTTP transport. In your workspace, you can connect directly:

```json
{
  "mcpServers": {
    "splat": {
      "url": "http://localhost:3030/mcp",
      "transport": {
        "type": "http",
        "headers": {
          "Authorization": "Bearer your-generated-token-here"
        }
      }
    }
  }
}
```

**4. Restart Claude Desktop or VS Code**

### Available MCP Tools

**Issue Management:**
- `list_recent_issues` - List recent issues by status
- `search_issues` - Search by keyword, exception type, or status
- `get_issue` - Get detailed issue with stack trace
- `get_issue_events` - List event occurrences for an issue
- `get_event` - Get full event details (request ID, breadcrumbs, context)
- `resolve_issue` / `ignore_issue` / `reopen_issue` - Lifecycle transitions

**Performance Monitoring:**
- `get_transaction_stats` - Overall percentiles plus top endpoints ranked by total time spent (avg × count)
- `get_endpoint_summary` - Per-endpoint percentiles (overall + DB + view) with fastest/slowest sample requests
- `get_endpoint_timeseries` - Bucketed count + p50/p95/p99 for one endpoint over a time range — built for spotting regressions ("did p95 jump after the 14:00 deploy?")
- `find_n_plus_one_endpoints` - Endpoints ranked by N+1 prevalence (% of transactions affected, avg/max queries per request) so you find the worst offenders quickly
- `search_slow_transactions` - Find slow individual requests
- `get_transactions_by_endpoint` - List recent transactions for one endpoint
- `compare_endpoint_performance` - Before/after percentile comparison around a release or timestamp
- `get_transaction` - Get detailed transaction breakdown

**Logs:**
- `search_logs` - Search structured logs by level, logger, trace, environment, or message text
- `get_log` - Get a single log record by `log_id`, including decompressed attributes
- `get_trace_logs` - Get all logs sharing a `trace_id`, oldest first — ties logs to a transaction/trace

### Usage Examples

Once configured, you can ask Claude:
- "List recent open issues in Splat"
- "Search for NoMethodError issues in production"
- "Where is the booko app spending its time?" → impact-ranked top endpoints
- "Which endpoints have N+1 query problems?" → ranked worklist
- "Show the p95 of UsersController#show over the last 7 days, hourly"
- "Compare AlertsController#index performance before and after release v1.42.0"
- "Search the logs for `status:422` POST requests in the last hour"
- "Show me every log line for trace abc123 in order" → reconstructs a request timeline

## Full List of Environment Variables
```
  RAILS_ENV: production
  SECRET_KEY_BASE : generate with `openssl rand -hex 64`
  HOST_IP: ip address to bind to
  PORT: 3000
  SPLAT_DOMAIN: https://splat.example.com # Change this to your domain
  FROM_EMAIL: splat@splat.example.com # Change this to your email
  SOLID_QUEUE_THREADS: 3
  SOLID_QUEUE_PROCESSES: 1
  TUBER_URL: tuber:11300 # host:port of the Tuber work queue
```

### MCP (Model Context Protocol)
```
MCP_AUTH_TOKEN: Generate with `openssl rand -hex 32`
```

### Data Retention
```
SPLAT_MAX_EVENT_LIFE_DAYS=30
SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS=60
SPLAT_MAX_FILE_LIFE_DAYS=180
```

### Tuber Work Queue
```
TUBER_URL: tuber:11300   # host:port of the Tuber (beanstalkd-compatible) server
```

Ingestion is enqueued on Tuber. To watch the tubes live — pending/ready/reserved
counts, throughput — use [tuber-tui](https://github.com/tuberq/tuber):

```bash
tuber-tui --url <host>:11330   # the host-mapped Tuber port from compose
```

## OIDC Authentication Setup

Splat supports OpenID Connect (OIDC) authentication with automatic discovery URL configuration. This replaces the basic auth setup with proper user authentication.

### Quick Start with Discovery URLs

The preferred method is using OIDC discovery URLs - just set 3 environment variables:

```bash
# Required for OIDC authentication (app automatically adds .well-known path)
OIDC_DISCOVERY_URL=https://your-provider.com
OIDC_CLIENT_ID=your-client-id
OIDC_CLIENT_SECRET=your-client-secret
OIDC_PROVIDER_NAME=Your Provider Name  # Optional: Display name for login button
```

**Important**: Configure your OIDC provider with the callback URL: `https://your-splat-domain.com/auth/callback`

### Provider-Specific Examples

**Google:**
```bash
OIDC_DISCOVERY_URL=https://accounts.google.com/.well-known/openid_configuration
OIDC_CLIENT_ID=your-google-client-id
OIDC_CLIENT_SECRET=your-google-client-secret
OIDC_PROVIDER_NAME=Google
```

**Okta:**
```bash
OIDC_DISCOVERY_URL=https://your-domain.okta.com/.well-known/openid_configuration
OIDC_CLIENT_ID=your-okta-client-id
OIDC_CLIENT_SECRET=your-okta-client-secret
OIDC_PROVIDER_NAME=Okta
```

**Auth0:**
```bash
OIDC_DISCOVERY_URL=https://your-domain.auth0.com/.well-known/openid_configuration
OIDC_CLIENT_ID=your-auth0-client-id
OIDC_CLIENT_SECRET=your-auth0-client-secret
OIDC_PROVIDER_NAME=Auth0
```

**Microsoft Azure AD:**
```bash
OIDC_DISCOVERY_URL=https://login.microsoftonline.com/your-tenant-id/v2.0/.well-known/openid_configuration
OIDC_CLIENT_ID=your-azure-client-id
OIDC_CLIENT_SECRET=your-azure-client-secret
OIDC_PROVIDER_NAME=Microsoft
```

### Manual Endpoint Configuration

If your provider doesn't support discovery URLs, configure endpoints individually:

```bash
# Required OIDC settings
OIDC_CLIENT_ID=your-client-id
OIDC_CLIENT_SECRET=your-client-secret
OIDC_AUTH_ENDPOINT=https://your-provider.com/oauth/authorize
OIDC_TOKEN_ENDPOINT=https://your-provider.com/oauth/token
OIDC_USERINFO_ENDPOINT=https://your-provider.com/oauth/userinfo
OIDC_JWKS_ENDPOINT=https://your-provider.com/.well-known/jwks.json
OIDC_PROVIDER_NAME=Your Provider
```


### How It Works

1. **Discovery**: The app automatically fetches OIDC configuration from your provider's discovery URL
2. **Authentication**: Users are redirected to your OIDC provider for login
3. **Token Storage**: JWT tokens are encrypted and stored in secure HTTP-only cookies
4. **Auto-Refresh**: Tokens are automatically refreshed when needed (5 minutes before expiry)
5. **Session Migration**: Existing sessions are automatically migrated to encrypted cookies

### Security Features

- **Encrypted Cookies**: JWT tokens are encrypted using Rails message verifier
- **HTTP-Only Cookies**: Tokens not accessible via JavaScript
- **SameSite=Strict**: Protection against CSRF attacks
- **JWT Verification**: Optional token signature validation
- **Automatic Cleanup**: Tokens cleared on logout or expiry

### Email Sending Setup
```
  https://guides.rubyonrails.org/action_mailer_basics.html#action-mailer-configuration
  https://guides.rubyonrails.org/configuring.html#configuring-action-mailer

  SMTP_ADDRESS - default 'localhost'
  SMTP_PORT - default 587
  SMTP_DOMAIN' - default 'localhost' Some providers require it match a verified domain.
  SMTP_USER_NAME' - default nil
  SMTP_PASSWORD' - default nil
  SMTP_AUTHENTICATION' - default 'plain'
  SMTP_STARTTLS_AUTO' - default 'true'
  SMTP_OPENSSL_VERIFY_MODE - default'none').to_sym
  ```

### Development

#### Services
- **Solid Queue**: Background job processing (`bin/jobs`)
- **Solid Cache**: In-memory caching
- **Solid Cable**: Real-time updates (optional)

#### Email Previews
View email templates at `http://localhost:3000/rails/mailers`

