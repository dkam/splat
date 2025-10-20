# Splat - Lightweight Error Tracker

This software is untested in production and should be considered alpha quality. It is partly an experiement in using SQLite extensively in a write heavy service. Will it blend, or will I need to switch to PostgreSQL? Lets find out!

Splat is a simple, error tracking service inspired by GlitchTip. It provides a lightweight alternative to Sentry for applications that need fast, reliable error monitoring.  Splat currently has no user accounts.

## Overview

**Named after Ruby's splat operator and the satisfying sound of squashing bugs**, Splat accepts Sentry-compatible error events and transaction data via a simple API endpoint, processes them asynchronously, and presents them in a clean, fast web interface.

### Key Features
- ✅ **Sentry Protocol Compatible** - Drop-in replacement for Sentry client SDKs
- ✅ **Single-Tenant Design** - Simple setup, no user management overhead
- ✅ **Fast Ingestion** - Errors appear in the UI within seconds
- ✅ **Performance Monitoring** - Transaction data with lightweight metrics
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
SMTP_OPENSSL_VERIFY_MODE=peer
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
  RAILS_MASTER_KEY: ${RAILS_MASTER_KEY}
  SPLAT_HOST: ${SPLAT_HOST}
  SMTP_ADDRESS: ${SMTP_ADDRESS}
  SMTP_PORT: ${SMTP_PORT}
  SMTP_USER_NAME: ${SMTP_USER_NAME}
  SMTP_PASSWORD: ${SMTP_PASSWORD}

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

## Full List of Environment Variables
  RAILS_ENV: production
  SECRET_KEY_BASE : generate with `openssl rand -hex 64`
  HOST_IP: ip address to bind to
  PORT: 3000
  SPLAT_DOMAIN: https://splat.example.com # Change this to your domain
  FROM_EMAIL: splat@splat.example.com # Change this to your email
  SOLID_QUEUE_THREADS: 3
  SOLID_QUEUE_PROCESSES: 1

### Data Retenion
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