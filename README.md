# Splat - Lightweight Error Tracker

This software is untested in production and should be considered alpha quality. It is partly an experiement in using SQLite extensively in a write heavy service. Will it blend, or will I need to switch to PostgreSQL? Lets find out!

Splat is a simple, error tracking service inspired by GlitchTip. It provides a lightweight alternative to Sentry for applications that need fast, reliable error monitoring.  Splat currently has no user accounts.

I've only used it with Rails and have been extracting the view / database times. T

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
- Shows errors within seconds
- Can be understood and modified in one sitting
- Rails 8 / Ruby 3.4.6 / SQLite3 + Solid stack (Queue/Cache/Cable) - SQLite-first architecture

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
SPLAT_HOST=localhost:3000

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

## Model Context Protocol (MCP) Integration

Splat exposes an MCP server that allows Claude and other AI assistants to query error tracking and performance data directly.

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
  RAILS_ENV: production
  SECRET_KEY_BASE : generate with `openssl rand -hex 64`
  HOST_IP: ip address to bind to
  PORT: 3000
  SPLAT_DOMAIN: https://splat.example.com # Change this to your domain
  FROM_EMAIL: splat@splat.example.com # Change this to your email
  SOLID_QUEUE_THREADS: 3
  SOLID_QUEUE_PROCESSES: 1

### MCP (Model Context Protocol)
MCP_AUTH_TOKEN: Generate with `openssl rand -hex 32`

### Data Retention
SPLAT_MAX_EVENT_LIFE_DAYS=30
SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS=60
SPLAT_MAX_FILE_LIFE_DAYS=180

### Mission Control
Optionally set these if you'd like to access /jobs to view the SolidQueue management system
  MISSION_CONTROL_USERNAME
  MISSION_CONTROL_PASSWORD

### Email Sending Setup
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