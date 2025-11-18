Use use the oauth


# Splat - Lightweight Error Tracker

This software is experiemental. If you'd like to try it out, find bugs, security flaws and improvements, please do. 

Splat is a simple, error tracking service inspired by GlitchTip. It provides a lightweight alternative to Sentry for applications that need fast, reliable error monitoring.

This app has zero authentication. I run it within tailscale and expose it via Caddy + Basic Auth, but the data ingestion is internal to tailscale. I'm planning to add OIDC.

It has an (awesome) MCP endpoint. You need to set an environment variable `MCP_AUTH_TOKEN` in order to use it. The end point is /mcp.

A large percentage of it is written with GLM 4.6 and Sonnet 4.5. It is partly an experiement in using SQLite extensively in a write heavy service. Will it blend, or will I need to switch to PostgreSQL? Lets find out!

I've only used Splat with Rails, but there's no reason it shouldn't work with other systems. Happy to accept pull requests for wider compatibility.

If you're looking for other Sentry clones, take a look at Glitchtip, Bugsink & Telebugs. 

## Overview

**Named after Ruby's splat operator and the satisfying sound of squashing bugs**, Splat accepts Sentry-compatible error events and transaction data via a simple API endpoint, processes them asynchronously, and presents them in a clean, fast web interface.

### Key Features
- ✅ **Sentry Protocol Compatible** - Drop-in replacement for Sentry client SDKs
- ✅ **Single-Tenant Design** - Simple setup, no user management overhead
- ✅ **Fast Ingestion** - Errors appear in the UI within seconds
- ✅ **Performance Monitoring** - Transaction data with lightweight metrics
- ✅ **MCP Integration** - Query errors via Claude and AI assistants
- ✅ **Minimal Dependencies** - Rails + SQLite + Solid Queue
- ✅ **Auto-Cleanup** - Configurable data retention (default 90 days)

### Why Splat?
When you need error tracking that:
- Your code assistant can grab issues and stack traces from
- Shows errors within seconds
- Can be understood and modified in one sitting
- Rails 8 / Ruby 3.4.6 / SQLite3 + Solid stack (Queue/Cache/Cable) - SQLite-first architecture


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
- Ruby 3.4.6+
- Rails 8+
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

### Development

#### Services
- **Solid Queue**: Background job processing (`bin/jobs`)
- **Solid Cache**: In-memory caching
- **Solid Cable**: Real-time updates (optional)

#### Email Previews
View email templates at `http://localhost:3000/rails/mailers`

### Deployment

Deploy using Kamal, Docker, or traditional Rails deployment methods.

**Important**: Configure SMTP settings before deploying to production to ensure email notifications work correctly.

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

services:
  splat:
    image: reg.tbdb.info/splat:latest
    environment:
      <<: *common-variables
      MISSION_CONTROL_USERNAME: ${MISSION_CONTROL_USERNAME}
      MISSION_CONTROL_PASSWORD: ${MISSION_CONTROL_PASSWORD}
    volumes:
      - /storage/splat/storage:/rails/storage
      - /storage/splat/logs/web:/rails/log
    ports:
      - "${HOST_IP}:3030:3000"
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  jobs:
    image: reg.tbdb.info/splat:latest
    environment:
      <<: *common-variables
      SOLID_QUEUE_THREADS: 3
      SOLID_QUEUE_PROCESSES: 1
    volumes:
      - /storage/splat/storage:/rails/storage
      - /storage/splat/logs/jobs:/rails/log
    command: bundle exec bin/jobs
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "3"
```

## Caddy Configuration

Assuming a Caddy server which forwards traffic to Splat. 

### Basic Auth
This configuration uses basic auth, but allows free access to the `/api/` and `/mcp/` endpoints.

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

### Forward Auth

```
splat.booko.info {
  encode zstd gzip

  # Handle /api/* and /mcp/* routes without basic auth (both use token auth)
  handle /api/* /mcp* {
    reverse_proxy * {
      to http://<ip address>:3030
    }
  }


  handle {
    forward_auth https://auth.booko.info {
      uri /api/verify?rd=https://auth.booko.info
      copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
    reverse_proxy * {
      to http://<ip address>:3030
    }
  }
}
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

## Maintenance

### Data Retention and Cleanup

Splat automatically cleans up old data to manage database size and maintain performance.

#### Default Retention Periods
- **Events/Issues**: 90 days (configurable via `SPLAT_MAX_EVENT_LIFE_DAYS`)
- **Transactions**: 90 days (configurable via `SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS`)
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

### Available MCP Tools (8 total)

**Issue Management:**
- `list_recent_issues` - List recent issues by status
- `search_issues` - Search by keyword, exception type, or status
- `get_issue` - Get detailed issue with stack trace
- `get_issue_events` - List event occurrences for an issue
- `get_event` - Get full event details (request ID, breadcrumbs, context)

**Performance Monitoring:**
- `get_transaction_stats` - Performance overview with percentiles
- `search_slow_transactions` - Find slow requests
- `get_transaction` - Get detailed transaction breakdown

### Usage Examples

Once configured, you can ask Claude:
- "List recent open issues in Splat"
- "Search for NoMethodError issues in production"
- "Show me performance stats for the last 24 hours"
- "Find slow POST requests"
- "Get event abc-123-def with full context and request ID"

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

### Mission Control
```
Optionally set these if you'd like to access /jobs to view the SolidQueue management system
  MISSION_CONTROL_USERNAME
  MISSION_CONTROL_PASSWORD
```

## OIDC Authentication Setup

Splat supports OpenID Connect (OIDC) authentication with automatic discovery URL configuration. This replaces the basic auth setup with proper user authentication.

### Quick Start with Discovery URLs

The preferred method is using OIDC discovery URLs - just set 3 environment variables:

```bash
# Required for OIDC authentication
OIDC_DISCOVERY_URL=https://your-provider.com/.well-known/openid_configuration
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

### Optional Configuration

```bash
# JWT signature verification (recommended for production)
OIDC_VERIFY_JWT_SIGNATURE=true

# Cookie settings
COOKIE_EXPIRY_HOURS=24                    # Default: 24 hours
COOKIE_DOMAIN=yourdomain.com               # Optional: Set for cross-subdomain auth
```

### Caddy Configuration (with OIDC)

When using OIDC authentication, Caddy simply passes all traffic to Splat - no external auth needed:

```
splat.booko.info {
  encode zstd gzip

  # All traffic goes to Splat - it handles OIDC internally
  reverse_proxy * {
    to http://<ip address>:3030
  }

  log {
    output file /var/log/caddy/splat.log
  }
}
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
