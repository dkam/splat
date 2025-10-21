# Splat - Lightweight Error Tracker

## Project Overview

**Splat** is a simple, single-tenant error tracking service. Named after Ruby's splat operator and the satisfying sound of squashing bugs.

### Why Building This

Need a fast, simple error tracker that:
- Shows errors within seconds
- Has minimal dependencies (Rails + SQLite3)
- Can be understood and modified easily

### Design Philosophy

**Simplicity over features:**
- ❌ No users, teams, or project management
- ❌ No multi-tenancy complexity
- ❌ No authentication (single-tenant, trust the network)
- ✅ Single DSN - all events go to one place
- ✅ Fast ingestion and display
- ✅ Just works

## Technology Stack

- **Rails 8 (edge)** - Latest features
- **SQLite** - Simple, fast, reliable storage
- **Solid Queue** - Background job processing
- **Solid Cache** - Counters and statistics
- **Solid Cable** - Real-time UI updates (optional)
- **Phlex** - Component-based UI

## Sentry Protocol Overview

### DSN Format
```
{PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PROJECT_ID}
```

Example: `https://abc123@splat.booko.info/1`

- **PUBLIC_KEY**: Random auth token (we'll ignore it or use ENV var)
- **PROJECT_ID**: Project identifier (we'll use `1` or ignore it)
- **HOST**: Where to send events

### Event Types

1. **Error Events** (REQUIRED)
   - Exceptions and error messages
   - Stack traces, context, fingerprints

2. **Transaction Events** (Performance Monitoring)
   - Request timings, database queries, external calls
   - Store lightweight - just the stats, not full traces

### Envelope Format

Events are sent as "envelopes" via POST to `/api/{project_id}/envelope/`:

```
{envelope_headers}\n
{item_headers}\n
{item_payload}\n
```

Example:
```
{"event_id":"abc123","sent_at":"2025-10-17T00:00:00.000Z"}\n
{"type":"event","length":1234}\n
{"message":"Something broke","exception":[...]}\n
```

**Protocol Reference**: https://develop.sentry.dev/sdk/envelopes/

## Database Schema

### Core Tables

```ruby
# events - Raw events from Sentry
create_table :events do |t|
  t.string :event_id, null: false, index: true  # UUID from Sentry
  t.datetime :timestamp, null: false, index: true
  t.string :platform                             # ruby, python, etc.
  t.string :sdk_name
  t.string :sdk_version

  # Error details
  t.string :exception_type, index: true
  t.text :exception_value
  t.text :message

  # Context
  t.string :environment                          # production, staging
  t.string :release
  t.string :server_name                          # which server sent it
  t.string :transaction                          # controller#action

  # Grouping
  t.json :fingerprint                            # Array for grouping similar errors
  t.bigint :issue_id, index: true               # Link to grouped issue

  # Full payload for details view
  t.json :payload                                # Complete event data

  t.timestamps
end

# issues - Grouped events by fingerprint
create_table :issues do |t|
  t.string :fingerprint, null: false, index: true  # Unique grouping key
  t.string :title, null: false                      # Human-readable summary
  t.string :exception_type

  # Statistics
  t.integer :count, default: 0
  t.datetime :first_seen, null: false
  t.datetime :last_seen, null: false

  # Status (enum: 0=unresolved, 1=resolved, 2=ignored)
  t.integer :status, default: 0, null: false

  t.timestamps
end

# transactions - Performance monitoring (lightweight)
create_table :transactions do |t|
  t.string :transaction_id, null: false, index: true  # UUID from Sentry
  t.datetime :timestamp, null: false, index: true
  t.string :transaction_name, null: false, index: true  # e.g., "ProductsController#show"
  t.string :op                                          # e.g., "http.server"

  # Timings (milliseconds)
  t.integer :duration, null: false                      # Total request time
  t.integer :db_time                                    # Database query time
  t.integer :view_time                                  # View rendering time

  # Context
  t.string :environment
  t.string :release
  t.string :server_name

  # HTTP specifics (if applicable)
  t.string :http_method                                 # GET, POST, etc.
  t.string :http_status                                 # 200, 404, 500, etc.
  t.string :http_url                                    # Request path

  # Lightweight payload for details
  t.json :tags                                          # Custom tags
  t.json :measurements                                  # Custom metrics

  t.timestamps

  # Indexes for performance queries
  t.index [:transaction_name, :timestamp]
  t.index [:environment, :timestamp]
  t.index :duration
end
```

## API Endpoints

### Ingest Endpoint
```ruby
# POST /api/:project_id/envelope/
# Accepts Sentry envelope format
# Returns: 200 OK (always, to avoid client retries)

class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    # Parse envelope
    # Queue processing job
    # Return success immediately
    head :ok
  end
end
```

### Health Check
```ruby
# GET /_health/
# Returns: { status: "ok", queue_depth: 0, event_count: 1234 }

class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      queue_depth: SolidQueue::Job.pending.count,
      event_count: Event.count,
      issue_count: Issue.where(status: 'unresolved').count
    }
  end
end
```

## Processing Pipeline

### 1. Receive Envelope
```ruby
# Parse multiline envelope format
lines = request.body.read.split("\n")
envelope_headers = JSON.parse(lines[0])
item_headers = JSON.parse(lines[1])
item_payload = JSON.parse(lines[2])
```

### 2. Queue Processing
```ruby
# Determine event type and route to appropriate job
case item_headers['type']
when 'event'
  ProcessEventJob.perform_later(
    event_id: envelope_headers['event_id'],
    payload: item_payload
  )
when 'transaction'
  ProcessTransactionJob.perform_later(
    transaction_id: envelope_headers['event_id'],
    payload: item_payload
  )
end
```

### 3. Process Event (Solid Queue job)
```ruby
class ProcessEventJob < ApplicationJob
  def perform(event_id:, payload:)
    # 1. Generate fingerprint for grouping
    fingerprint = generate_fingerprint(payload)

    # 2. Find or create issue
    issue = Issue.find_or_create_by(fingerprint: fingerprint) do |i|
      i.title = extract_title(payload)
      i.exception_type = payload.dig('exception', 'values', 0, 'type')
      i.first_seen = Time.current
      i.last_seen = Time.current
    end

    # 3. Create event record
    Event.create!(
      event_id: event_id,
      issue: issue,
      timestamp: payload['timestamp'],
      payload: payload,
      # ... extract other fields
    )

    # 4. Auto-reopen resolved issues (following GlitchTip behavior)
    # - resolved → unresolved (new event reopens the issue)
    # - ignored → stays ignored (you explicitly don't want to see it)
    if issue.resolved?
      issue.unresolved!
    end

    # 5. Update issue stats
    issue.increment!(:count)
    issue.touch(:last_seen)
  end

  private

  def generate_fingerprint(payload)
    # Use Sentry's fingerprint if provided
    if payload['fingerprint'].present?
      payload['fingerprint'].join('::')
    else
      # Generate from exception type + location
      type = payload.dig('exception', 'values', 0, 'type')
      file = payload.dig('exception', 'values', 0, 'stacktrace', 'frames', -1, 'filename')
      line = payload.dig('exception', 'values', 0, 'stacktrace', 'frames', -1, 'lineno')
      "#{type}::#{file}::#{line}"
    end
  end

  def extract_title(payload)
    payload.dig('exception', 'values', 0, 'value') ||
      payload['message'] ||
      payload.dig('exception', 'values', 0, 'type') ||
      'Unknown Error'
  end
end

class ProcessTransactionJob < ApplicationJob
  def perform(transaction_id:, payload:)
    # Extract key metrics only - don't store massive traces
    Transaction.create!(
      transaction_id: transaction_id,
      timestamp: payload['timestamp'],
      transaction_name: payload['transaction'],
      op: payload['contexts']&.dig('trace', 'op'),

      # Convert seconds to milliseconds
      duration: (payload['timestamp'] - payload['start_timestamp']).to_f * 1000,

      # Extract measurements
      db_time: payload.dig('measurements', 'db', 'value'),
      view_time: payload.dig('measurements', 'view', 'value'),

      # Context
      environment: payload['environment'],
      release: payload['release'],
      server_name: payload['server_name'],

      # HTTP context
      http_method: payload.dig('request', 'method'),
      http_status: payload.dig('contexts', 'response', 'status_code'),
      http_url: payload.dig('request', 'url'),

      # Store tags and custom measurements as JSON
      tags: payload['tags'],
      measurements: payload['measurements']
    )
  rescue => e
    # Log but don't fail - performance data is nice-to-have
    Rails.logger.error("Failed to process transaction: #{e.message}")
  end
end
```

## Models

### Issue Model

```ruby
class Issue < ApplicationRecord
  belongs_to :project
  has_many :events, dependent: :nullify

  # Status enum (following GlitchTip pattern)
  # - unresolved (0): Active issue needing attention
  # - resolved (1): Fixed, but will auto-reopen on new events
  # - ignored (2): Explicitly ignored, stays ignored on new events
  enum :status, { unresolved: 0, resolved: 1, ignored: 2 }

  validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true

  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }
  # Enum automatically provides scopes: Issue.unresolved, Issue.resolved, Issue.ignored

  def record_event!(timestamp: Time.current)
    update!(
      count: count + 1,
      last_seen: timestamp
    )
  end

  # Enum automatically provides:
  # - Checkers: resolved?, ignored?, unresolved?
  # - Setters: resolved!, ignored!, unresolved!
end
```

**Status behavior on new events** (matches GlitchTip):
- `resolved` → automatically changed to `unresolved`
- `ignored` → stays `ignored` (explicit "don't care" decision)
- `unresolved` → stays `unresolved`

## UI Views (ERB + Tailwindcss)

### Issues List
```ruby
class Views::Issues::Index < ApplicationView
  def template
    h1 { "Issues" }

    div(class: "issues") do
      @issues.each do |issue|
        render IssueCard.new(issue)
      end
    end
  end
end

class Views::Issues::IssueCard < ApplicationView
  def initialize(issue)
    @issue = issue
  end

  def template
    div(class: "issue-card") do
      h2 { a(href: issue_path(@issue)) { @issue.title } }
      p { "#{@issue.exception_type} • #{@issue.count} events" }
      p(class: "text-muted") do
        "Last seen: #{time_ago_in_words(@issue.last_seen)} ago"
      end
    end
  end
end
```

### Issue Detail
```ruby
class Views::Issues::Show < ApplicationView
  def template
    h1 { @issue.title }

    div(class: "issue-stats") do
      p { "Type: #{@issue.exception_type}" }
      p { "Count: #{@issue.count} occurrences" }
      p { "First seen: #{@issue.first_seen}" }
      p { "Last seen: #{@issue.last_seen}" }
    end

    h2 { "Recent Events" }
    @issue.events.recent.each do |event|
      render EventCard.new(event)
    end
  end
end
```

## Configuration

### Routes
```ruby
Rails.application.routes.draw do
  # Sentry ingestion endpoint
  namespace :api do
    post ':project_id/envelope', to: 'envelopes#create'
  end

  # Health check
  get '_health', to: 'health#show'

  # UI
  root to: 'issues#index'
  resources :issues, only: [:index, :show] do
    member do
      patch :resolve
      patch :ignore
    end
  end

  resources :events, only: [:show]

  resources :transactions, only: [:index, :show] do
    collection do
      get :slow  # Show slowest transactions
      get :by_endpoint  # Group by endpoint
    end
  end
end
```

## Performance Monitoring UI

### Transaction List

```ruby
class Views::Transactions::Index < ApplicationView
  def template
    h1 { "Performance" }

    # Summary stats
    div(class: "stats") do
      div { "Avg Response: #{@avg_duration}ms" }
      div { "P95: #{@p95_duration}ms" }
      div { "P99: #{@p99_duration}ms" }
    end

    # Top slow transactions
    h2 { "Slowest Endpoints" }
    table do
      thead do
        tr do
          th { "Endpoint" }
          th { "Avg Duration" }
          th { "Count" }
          th { "Slowest" }
        end
      end
      tbody do
        @slow_endpoints.each do |endpoint|
          tr do
            td { a(href: transactions_by_endpoint_path(endpoint: endpoint.transaction_name)) { endpoint.transaction_name } }
            td { "#{endpoint.avg_duration.round}ms" }
            td { endpoint.count }
            td { "#{endpoint.max_duration.round}ms" }
          end
        end
      end
    end
  end
end

# app/controllers/transactions_controller.rb
class TransactionsController < ApplicationController
  def index
    @transactions = Transaction.recent.limit(100)

    # Calculate percentiles
    durations = Transaction.where('timestamp > ?', 1.hour.ago).pluck(:duration).sort
    @avg_duration = durations.sum / durations.size if durations.any?
    @p95_duration = durations[durations.size * 0.95] if durations.any?
    @p99_duration = durations[durations.size * 0.99] if durations.any?

    # Group by endpoint
    @slow_endpoints = Transaction
      .where('timestamp > ?', 24.hours.ago)
      .group(:transaction_name)
      .select('transaction_name, AVG(duration) as avg_duration, COUNT(*) as count, MAX(duration) as max_duration')
      .order('avg_duration DESC')
      .limit(20)
  end

  def slow
    @transactions = Transaction
      .where('timestamp > ?', 24.hours.ago)
      .where('duration > ?', 1000)  # Slower than 1 second
      .order(duration: :desc)
      .limit(100)
  end

  def by_endpoint
    @endpoint = params[:endpoint]
    @transactions = Transaction
      .where(transaction_name: @endpoint)
      .where('timestamp > ?', 24.hours.ago)
      .order(timestamp: :desc)
      .limit(100)
  end
end
```

### Simple Charts (Optional)

For basic visualization without heavy JS libraries:

```ruby
# app/components/views/transactions/duration_chart.rb
class Views::Transactions::DurationChart < ApplicationView
  def initialize(transactions)
    @transactions = transactions
  end

  def template
    # Simple ASCII-style bar chart using CSS
    div(class: "duration-chart") do
      @transactions.group_by { |t| t.timestamp.beginning_of_hour }.each do |hour, txns|
        avg = txns.sum(&:duration) / txns.size
        div(class: "bar") do
          span { hour.strftime("%H:%M") }
          div(class: "fill", style: "width: #{scale_duration(avg)}%") do
            span { "#{avg.round}ms" }
          end
        end
      end
    end
  end

  private

  def scale_duration(ms)
    # Scale to 0-100% based on max seen duration
    max = 5000  # Assume 5s is 100%
    [(ms / max.to_f * 100), 100].min
  end
end
```

### Environment Variables
```ruby
# .env
SPLAT_DSN=http://ignored@splat.booko.info/1
RAILS_ENV=production
DATABASE_URL=sqlite3:storage/production.sqlite3

# MCP (Model Context Protocol) Authentication
# Generate a secure token for Claude/AI assistants to query error data
MCP_AUTH_TOKEN=your-generated-token-here
```

**Generate MCP Auth Token:**
```bash
# Using OpenSSL
openssl rand -hex 32

# Or using Ruby
ruby -r securerandom -e 'puts SecureRandom.hex(32)'

# Example output:
# 6ba04de38d45e51a829f05d5934b0fef1b8eee91a840d9347a02b2d4cc479d0a
```

### Sentry Client Configuration (Booko)
```ruby
# In Booko's config/initializers/sentry.rb
config.dsn = ENV.fetch('SPLAT_DSN', 'http://ignored@splat.booko.info/1')

# Enable performance monitoring - but keep it LOW
config.traces_sample_rate = 0.01  # Only 1% of requests
# Or use custom sampler for slow requests only
config.traces_sampler = lambda do |sampling_context|
  # Always sample slow transactions
  if sampling_context[:parent_sampled] == true
    1.0
  else
    0.01  # 1% of normal requests
  end
end
```

### Performance Data Retention

Since transactions can accumulate quickly, implement automatic cleanup:

```ruby
# app/jobs/cleanup_transactions_job.rb
class CleanupTransactionsJob < ApplicationJob
  def perform
    # Keep last 7 days of transaction data
    Transaction.where('timestamp < ?', 7.days.ago).delete_all

    # Or keep aggregated stats but delete individual transactions after 24h
    # (Implement daily aggregation table if needed)
  end
end

# config/initializers/solid_queue.rb
# Schedule cleanup daily
config.recurring_tasks = [
  { class: "CleanupTransactionsJob", schedule: "0 2 * * *" }  # 2am daily
]
```

## Deployment

### Setup
```bash
# Generate Rails app
rails new splat --edge --database=sqlite3

cd splat

# Install Solid gems
bundle add solid_queue solid_cache solid_cable

# Setup
bin/rails solid_queue:install
bin/rails solid_cache:install
bin/rails solid_cable:install

# Generate scaffolds
bin/rails generate model Event event_id:string timestamp:datetime ...
bin/rails generate model Issue fingerprint:string title:string ...
bin/rails generate controller Api::Envelopes
bin/rails generate job ProcessEvent

# Migrate
bin/rails db:migrate
```

### Running
```bash
# Development
bin/dev  # Runs Rails + Solid Queue worker

# Production
bin/rails server
bin/jobs  # Solid Queue worker
```

## Monitoring

### Uptime Kuma Integration
```bash
#!/bin/bash
# Monitor Solid Queue depth
QUEUE_DEPTH=$(bin/rails runner 'puts SolidQueue::Job.pending.count')
curl "https://status.booko.info/api/push/MONITOR_ID?status=up&msg=Queue:+${QUEUE_DEPTH}&ping=${QUEUE_DEPTH}"
```

## Authentication & Authorization

### OAuth Integration with Booko (or any OAuth provider)

Splat uses OAuth to authenticate users without managing its own user database.

#### 1. Register Splat in Booko

Create an OAuth application in Booko:

```ruby
# In Booko's OAuth applications UI or rails console
OauthApplication.create!(
  name: "Splat",
  redirect_uri: "https://splat.booko.info/auth/booko/callback",
  scopes: "user:read"
)
# Returns: client_id and client_secret
```

#### 2. Configure OmniAuth in Splat

```ruby
# Gemfile
gem 'omniauth-oauth2'
gem 'omniauth-rails_csrf_protection'  # CSRF protection for OmniAuth

# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :oauth2, ENV['OAUTH_CLIENT_ID'], ENV['OAUTH_CLIENT_SECRET'],
    client_options: {
      site: ENV['OAUTH_SITE'],              # https://booko.info
      authorize_url: '/oauth/authorize',
      token_url: '/oauth/token',
      user_info_url: '/api/v3/user'
    },
    name: :booko
end
```

#### 3. Authorization - Allowlist with Domain Matching

```ruby
# config/initializers/splat.rb
module Splat
  class << self
    def authorized?(email)
      return false if email.blank?

      # Check exact email matches
      return true if allowed_emails.include?(email)

      # Check domain matches
      domain = email.split('@').last
      allowed_domains.any? { |allowed| domain == allowed || domain.end_with?(".#{allowed}") }
    end

    private

    def allowed_emails
      @allowed_emails ||= ENV.fetch('SPLAT_ALLOWED_USERS', '').split(',').map(&:strip)
    end

    def allowed_domains
      @allowed_domains ||= ENV.fetch('SPLAT_ALLOWED_DOMAINS', '').split(',').map(&:strip)
    end
  end
end
```

#### 4. Sessions Controller

```ruby
# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: [:create, :failure]

  def create
    auth = request.env['omniauth.auth']
    email = auth.dig('info', 'email')

    unless Splat.authorized?(email)
      redirect_to root_path, alert: "Not authorized. Contact admin for access."
      return
    end

    session[:user_email] = email
    session[:user_name] = auth.dig('info', 'name') || email

    redirect_to root_path, notice: "Welcome #{session[:user_name]}!"
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Logged out"
  end

  def failure
    redirect_to root_path, alert: "Authentication failed: #{params[:message]}"
  end
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :require_authentication

  private

  def require_authentication
    return if authenticated?

    session[:return_to] = request.fullpath
    redirect_to '/auth/booko'
  end

  def authenticated?
    session[:user_email].present?
  end

  def current_user_email
    session[:user_email]
  end

  def current_user_name
    session[:user_name] || current_user_email
  end

  helper_method :current_user_email, :current_user_name, :authenticated?
end
```

#### 5. Routes

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # OAuth callbacks
  get '/auth/:provider/callback', to: 'sessions#create'
  get '/auth/failure', to: 'sessions#failure'
  post '/auth/:provider/callback', to: 'sessions#create'  # For CSRF protection
  delete '/logout', to: 'sessions#destroy'

  # ... rest of routes
end
```

#### 6. Environment Configuration

```bash
# .env
# OAuth Provider (Booko)
OAUTH_CLIENT_ID=abc123
OAUTH_CLIENT_SECRET=xyz789
OAUTH_SITE=https://booko.info

# Authorization - Specific emails
SPLAT_ALLOWED_USERS=admin@example.com,dkam@booko.info

# Authorization - Allowed domains (will match user@booko.au, user@any.booko.au, etc.)
SPLAT_ALLOWED_DOMAINS=booko.au,booko.info,booko.com.au
```

#### 7. UI - Login/Logout

```ruby
# app/components/views/layout/header.rb
class Views::Layout::Header < ApplicationView
  def template
    header(class: "header") do
      h1 { a(href: root_path) { "Splat 🐛💥" } }

      if authenticated?
        div(class: "user-menu") do
          span { "#{current_user_name}" }
          form(action: logout_path, method: :delete, style: "display: inline") do
            button(type: :submit) { "Logout" }
          end
        end
      end
    end
  end
end
```

### Authorization Patterns

**Pattern 1: Specific users only**
```bash
SPLAT_ALLOWED_USERS=alice@example.com,bob@example.com
SPLAT_ALLOWED_DOMAINS=
```

**Pattern 2: Anyone from specific domains**
```bash
SPLAT_ALLOWED_USERS=
SPLAT_ALLOWED_DOMAINS=mycompany.com,contractors.io
```

**Pattern 3: Mix of both**
```bash
SPLAT_ALLOWED_USERS=consultant@external.com,freelancer@somewhere.org
SPLAT_ALLOWED_DOMAINS=mycompany.com
```

**Pattern 4: Public subdomain matching**
```bash
# Allows anyone@booko.au, anyone@dev.booko.au, anyone@staging.booko.au
SPLAT_ALLOWED_DOMAINS=booko.au
```

### Using Different OAuth Providers

The same pattern works with any OAuth2 provider:

**GitHub:**
```ruby
provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET'],
  scope: 'user:email'
```

**Google:**
```ruby
provider :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET'],
  scope: 'email,profile'
```

**Generic OAuth2:**
```ruby
provider :oauth2, ENV['OAUTH_CLIENT_ID'], ENV['OAUTH_CLIENT_SECRET'],
  client_options: {
    site: ENV['OAUTH_SITE'],
    authorize_url: '/oauth/authorize',
    token_url: '/oauth/token'
  }
```

## Model Context Protocol (MCP) Integration

Splat exposes an MCP server that allows Claude and other AI assistants to query error tracking and performance data directly.

### Features

**8 Available Tools:**
1. `list_recent_issues` - List recent issues by status
2. `search_issues` - Search issues by keyword, exception type, or status
3. `get_issue` - Get detailed issue information with stack trace
4. `get_issue_events` - List recent event occurrences for an issue
5. `get_event` - Get full event details including request ID, breadcrumbs, and context
6. `get_transaction_stats` - Performance overview with percentiles and slowest endpoints
7. `search_slow_transactions` - Find slow requests with filtering
8. `get_transaction` - Get detailed transaction performance breakdown

### Setup for Claude Desktop

**1. Generate Auth Token (see Environment Variables section above)**

**2. Configure MCP Client**

**For Claude Desktop (stdio proxy required):**

Claude Desktop only supports `stdio` transport. Create a proxy script at `~/splat-mcp-proxy.sh`:

```bash
#!/bin/bash
# Proxy for Splat MCP over stdio -> HTTP
while IFS= read -r line; do
  echo "$line" | curl -s -X POST http://localhost:3030/mcp \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer YOUR_TOKEN_HERE" \
    -d @-
done
```

Make it executable and configure Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```bash
chmod +x ~/splat-mcp-proxy.sh
```

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

**For Claude Code (direct HTTP):**

Claude Code supports HTTP transport directly:

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

For production, use your Splat domain (HTTPS recommended):
```json
{
  "mcpServers": {
    "splat": {
      "url": "https://splat.booko.info/mcp",
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

**3. Restart Claude Desktop or VS Code**

### Usage Examples

Once configured, you can ask Claude:
- "List recent open issues in Splat"
- "Search for NoMethodError issues"
- "Show me performance stats for the last 24 hours"
- "Find slow transactions in production"
- "Get event abc-123-def with full context and request ID"

### Security

- **Token-based authentication** - Uses Bearer token for all requests
- **Read-only access** - MCP tools can query data but not modify anything
- **HTTPS recommended** - Use HTTPS in production to protect token in transit
- **Simple token rotation** - Just update `MCP_AUTH_TOKEN` and restart

### Implementation

- **No external dependencies** - Manual JSON-RPC 2.0 implementation
- **Single controller** - All MCP logic in `app/controllers/mcp/mcp_controller.rb`
- **Easy to extend** - Add new tools by defining in `tools_list` and implementing handler

## Future Enhancements (Maybe)

- [ ] Notification webhooks (Slack, Discord)
- [ ] Event search/filtering
- [ ] Trend graphs (events over time)
- [ ] Source code context (fetch from git)
- [ ] Multiple projects (if needed)
- [ ] Team/role management (if needed beyond email allowlist)
- [ ] MCP write tools (resolve/ignore issues, add comments)

## Success Criteria

1. ✅ Error events appear in UI within 5 seconds
2. ✅ Transaction data provides useful performance insights
3. ✅ Queue depth stays near zero (monitor with Uptime Kuma)
4. ✅ No dependencies on Python/Celery/Redis
5. ✅ Can handle Booko's production traffic
6. ✅ Simple enough to understand and modify in one sitting

## Getting Started

```bash
cd /Users/dkam/Development
rails new splat --edge --database=sqlite3
cd splat

# Follow setup instructions above
# Start building the envelope parser first
# Then the event processor
# Then the UI
```

## Reference Links

- Sentry Protocol: https://develop.sentry.dev/sdk/envelopes/
- Sentry Event Schema: https://develop.sentry.dev/sdk/event-payloads/
- Model Context Protocol: https://modelcontextprotocol.io/
- Rails Guides: https://edgeguides.rubyonrails.org/
- Solid Queue: https://github.com/basecamp/solid_queue
- Phlex: https://www.phlex.fun/

---

**Remember**: The goal is simplicity and reliability. When in doubt, ship the simpler version. We're building an error tracker, not recreating Sentry's entire feature set.

🐛💥 Happy bug squashing!
