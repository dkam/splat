# Recommended Code Improvements for Splat

This document provides specific, actionable improvements identified during the code review.
Each improvement includes the issue, code example, and recommended solution.

## High Priority Issues

### 1. Add Rate Limiting to API Endpoints

**File:** `app/controllers/api/envelopes_controller.rb`

**Issue:** The API endpoint `/api/:project_id/envelope` has no rate limiting, making it vulnerable to abuse or DDoS attacks.

**Current Code:**
```ruby
class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    project = authenticate_project!
    return head :not_found unless project
    # ... process envelope
  end
end
```

**Recommended Solution:**

Add a rate limiting concern:

```ruby
# app/controllers/concerns/api_rate_limitable.rb
module ApiRateLimitable
  extend ActiveSupport::Concern

  included do
    before_action :check_api_rate_limit, only: [:create]
  end

  private

  def check_api_rate_limit
    # Use combination of IP and project for rate limit key
    key = "api_envelope:#{request.ip}:#{params[:project_id]}"
    
    # Allow 100 requests per minute per IP/project combination
    limit = ENV.fetch('API_RATE_LIMIT', 100).to_i
    window = 1.minute
    
    current_count = Rails.cache.read(key) || 0
    
    if current_count >= limit
      Rails.logger.warn "Rate limit exceeded for #{request.ip} on project #{params[:project_id]}"
      render json: { 
        error: 'Rate limit exceeded. Please try again later.' 
      }, status: :too_many_requests
      return
    end
    
    Rails.cache.write(key, current_count + 1, expires_in: window, raw: true)
  end
end
```

Then include it in the controller:

```ruby
class Api::EnvelopesController < ApplicationController
  include ApiRateLimitable
  skip_before_action :verify_authenticity_token
  
  # ... rest of the controller
end
```

**Alternative:** Use Rack::Attack gem for more sophisticated rate limiting:

```ruby
# Gemfile
gem 'rack-attack'

# config/initializers/rack_attack.rb
class Rack::Attack
  # Throttle API envelope submissions
  throttle('api/envelopes', limit: 100, period: 1.minute) do |req|
    if req.path.start_with?('/api/') && req.path.end_with?('/envelope')
      # Return a unique identifier for the requester
      "#{req.ip}-#{req.params['project_id']}"
    end
  end
  
  # Custom response for throttled requests
  self.throttled_responder = lambda do |request|
    [ 429, 
      { 'Content-Type' => 'application/json' },
      [{ error: 'Rate limit exceeded' }.to_json]
    ]
  end
end
```

---

## Medium Priority Issues

### 2. Extract Transaction Statistics to Service Object

**File:** `app/models/transaction.rb`

**Issue:** The Transaction model is 278 lines and has too many responsibilities. Stats calculation should be extracted.

**Current Code:**
```ruby
class Transaction < ApplicationRecord
  # ... validations, scopes ...
  
  def self.stats_by_endpoint(time_range = 24.hours.ago..Time.current, project_id: nil)
    # Complex SQL logic
  end
  
  def self.percentiles(time_range = 24.hours.ago..Time.current, project_id: nil)
    # Complex SQL logic with NTILE
  end
  
  # ... more methods
end
```

**Recommended Solution:**

Create a service object:

```ruby
# app/services/transaction_stats_service.rb
class TransactionStatsService
  attr_reader :time_range, :project_id
  
  def initialize(time_range: 24.hours.ago..Time.current, project_id: nil)
    @time_range = time_range
    @project_id = project_id
  end
  
  def stats_by_endpoint(limit: 10)
    base_scope
      .group(:transaction_name)
      .select(
        :transaction_name,
        "AVG(duration) as avg_duration",
        "MIN(duration) as min_duration",
        "MAX(duration) as max_duration",
        "COUNT(*) as count",
        "AVG(db_time) as avg_db_time",
        "AVG(view_time) as avg_view_time"
      )
      .order("avg_duration DESC")
      .limit(limit)
  end
  
  def percentiles
    transaction_count = base_scope.count
    return default_percentiles if transaction_count.zero?
    
    # Use optimized query for large datasets
    if transaction_count > 10_000
      calculate_sampled_percentiles(transaction_count)
    else
      calculate_full_percentiles
    end
  end
  
  private
  
  def base_scope
    scope = Transaction.where(timestamp: time_range)
    scope = scope.where(project_id: project_id) if project_id.present?
    scope
  end
  
  def default_percentiles
    { avg: 0, p50: 0, p95: 0, p99: 0, min: 0, max: 0 }
  end
  
  def calculate_full_percentiles
    # Move complex SQL here
  end
  
  def calculate_sampled_percentiles(total_count)
    # Move sampling logic here
  end
end
```

Update the Transaction model:

```ruby
class Transaction < ApplicationRecord
  # ... keep basic scopes and instance methods
  
  # Delegate stats to service
  def self.stats_by_endpoint(time_range: 24.hours.ago..Time.current, project_id: nil)
    TransactionStatsService.new(time_range: time_range, project_id: project_id)
      .stats_by_endpoint
  end
  
  def self.percentiles(time_range: 24.hours.ago..Time.current, project_id: nil)
    TransactionStatsService.new(time_range: time_range, project_id: project_id)
      .percentiles
  end
end
```

---

### 3. Fix N+1 Query in Issue Events Display

**File:** `app/controllers/issues_controller.rb`

**Issue:** Events may trigger N+1 queries when accessing associated project data.

**Current Code:**
```ruby
def show
  @events = @issue.events.recent.limit(50)
end
```

**Recommended Solution:**

```ruby
def show
  # Eager load project to prevent N+1 queries
  @events = @issue.events
    .includes(:project)
    .recent
    .limit(50)
  
  # If event_row partial accesses other associations, add them too
  # .includes(:project, :issue)
end
```

**Testing with Bullet:**

Add to `Gemfile` (development group):

```ruby
group :development do
  gem 'bullet'
end
```

Configure in `config/environments/development.rb`:

```ruby
config.after_initialize do
  Bullet.enable = true
  Bullet.alert = true
  Bullet.bullet_logger = true
  Bullet.console = true
  Bullet.rails_logger = true
end
```

---

### 4. Extract Time Range Parsing to Concern

**File:** `app/controllers/transactions_controller.rb`

**Issue:** Time range parsing logic is duplicated across multiple controller actions.

**Current Code:**
```ruby
def index
  @time_range = params[:time_range] || "24h"
  # Convert to actual time range
  case @time_range
  when "1h" then time_range = 1.hour.ago..Time.current
  when "24h" then time_range = 24.hours.ago..Time.current
  # ...
  end
end

def slow
  @time_range = params[:time_range] || "24h"
  # Same logic repeated
end
```

**Recommended Solution:**

Create a concern:

```ruby
# app/controllers/concerns/time_range_parseable.rb
module TimeRangeParseable
  extend ActiveSupport::Concern
  
  private
  
  def parse_time_range(param = params[:time_range])
    range_string = param || "24h"
    
    case range_string
    when "1h"
      1.hour.ago..Time.current
    when "24h"
      24.hours.ago..Time.current
    when "7d"
      7.days.ago..Time.current
    when "30d"
      30.days.ago..Time.current
    else
      # Default to 24 hours
      24.hours.ago..Time.current
    end
  end
  
  def time_range_string
    @time_range_string ||= params[:time_range] || "24h"
  end
end
```

Update the controller:

```ruby
class TransactionsController < ApplicationController
  include TimeRangeParseable
  
  def index
    time_range = parse_time_range
    @time_range_string = time_range_string
    
    base_scope = @project.transactions.where(timestamp: time_range)
    # ... rest of the method
  end
  
  def slow
    time_range = parse_time_range
    @time_range_string = time_range_string
    
    @transactions = @project.transactions
      .where(timestamp: time_range)
      .where('duration > ?', threshold_ms)
    # ... rest of the method
  end
end
```

---

### 5. Improve Error Handling Specificity

**File:** `app/services/sentry_protocol/envelope_processor.rb`

**Issue:** Broad rescue block catches all exceptions, potentially hiding bugs.

**Current Code:**
```ruby
rescue => e
  Rails.logger.error "Error processing envelope: #{e.message}"
  Rails.logger.error e.backtrace.join("\n")
  true # Return true to avoid client retries on our internal errors
end
```

**Recommended Solution:**

```ruby
rescue JSON::ParserError => e
  Rails.logger.error "JSON parsing error: #{e.message}"
  false
rescue InvalidEnvelope => e
  Rails.logger.error "Invalid envelope format: #{e.message}"
  false
rescue ActiveRecord::RecordInvalid => e
  Rails.logger.error "Database validation error: #{e.message}"
  false
rescue StandardError => e
  # Only catch truly unexpected errors here
  Rails.logger.error "Unexpected error processing envelope: #{e.message}"
  Rails.logger.error e.backtrace.join("\n")
  
  # Report to error tracking if available
  Sentry.capture_exception(e) if defined?(Sentry)
  
  # Return true to prevent client retries for our internal errors
  true
end
```

---

## Low Priority Issues

### 6. Replace Magic Numbers with Constants

**File:** `app/controllers/transactions_controller.rb`

**Issue:** Magic numbers make code less readable and harder to maintain.

**Current Code:**
```ruby
def slow
  threshold = params[:threshold]&.to_i || 1000
end

# app/models/transaction.rb
def slow?
  duration.present? && duration > 1000
end
```

**Recommended Solution:**

```ruby
# app/models/transaction.rb
class Transaction < ApplicationRecord
  # Configuration constants
  SLOW_THRESHOLD_MS = 1000  # 1 second
  DEFAULT_BROADCAST_INTERVAL_SEC = 3
  
  def slow?
    duration.present? && duration > SLOW_THRESHOLD_MS
  end
  
  private
  
  def broadcast_interval
    ENV.fetch("TRANSACTION_BROADCAST_INTERVAL", DEFAULT_BROADCAST_INTERVAL_SEC).to_i
  end
end

# app/controllers/transactions_controller.rb
class TransactionsController < ApplicationController
  def slow
    threshold = params[:threshold]&.to_i || Transaction::SLOW_THRESHOLD_MS
    # ...
  end
end
```

---

### 7. Extract MCP Error Responses to Helper

**File:** `app/controllers/mcp/mcp_controller.rb`

**Issue:** Repeated JSON-RPC error response structure.

**Current Code:**
```ruby
render json: {
  jsonrpc: "2.0",
  error: {
    code: -32601,
    message: "Method not found: #{rpc_request["method"]}"
  },
  id: @rpc_id
}, status: :bad_request
```

**Recommended Solution:**

```ruby
private

def render_mcp_error(code, message, data: nil, status: :bad_request)
  error = { code: code, message: message }
  error[:data] = data if data.present?
  
  render json: {
    jsonrpc: "2.0",
    error: error,
    id: @rpc_id
  }, status: status
end

def render_mcp_success(result)
  render json: {
    jsonrpc: "2.0",
    result: result,
    id: @rpc_id
  }
end
```

Then use it:

```ruby
def handle_mcp_request
  case rpc_request["method"]
  when "initialize"
    render_mcp_success(initialize_result)
  when "tools/list"
    render_mcp_success({ tools: tools_list })
  else
    render_mcp_error(-32601, "Method not found: #{rpc_request['method']}")
  end
end
```

---

### 8. Add Partial Indexes for Common Queries

**File:** New migration

**Issue:** Some queries could benefit from partial indexes.

**Recommended Solution:**

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_partial_indexes.rb
class AddPartialIndexes < ActiveRecord::Migration[8.1]
  def change
    # Index for open issues only (most common query)
    add_index :issues, :last_seen, 
              where: "status = 0", 
              name: "index_issues_on_last_seen_open"
    
    # Index for slow transactions only
    add_index :transactions, [:project_id, :timestamp], 
              where: "duration > 1000",
              name: "index_slow_transactions_by_project"
    
    # Index for error events (non-transaction events)
    add_index :events, [:project_id, :timestamp],
              where: "exception_type IS NOT NULL",
              name: "index_error_events_by_project"
  end
end
```

---

### 9. Improve Broadcast Throttling Efficiency

**File:** `app/models/transaction.rb`

**Issue:** String-to-Time conversion is inefficient.

**Current Code:**
```ruby
def broadcast_transaction_update
  cache_key = "transaction_broadcast_#{project_id}"
  last_broadcast = Rails.cache.read(cache_key)
  throttle_interval = broadcast_interval
  
  # Inefficient: converts string to Time
  last_broadcast = Time.parse(last_broadcast) if last_broadcast.is_a?(String)
  
  if last_broadcast.nil? || last_broadcast < throttle_interval.seconds.ago
    Rails.cache.write(cache_key, Time.current, expires_in: 1.hour)
    project.broadcast_refresh_to(project, "transactions")
  end
end
```

**Recommended Solution:**

```ruby
def broadcast_transaction_update
  cache_key = "transaction_broadcast_#{project_id}"
  interval_seconds = broadcast_interval
  
  # Use integers (Unix timestamps) for simpler comparison
  now = Time.current.to_i
  last_broadcast_at = Rails.cache.read(cache_key)&.to_i || 0
  
  if (now - last_broadcast_at) >= interval_seconds
    Rails.cache.write(cache_key, now, expires_in: 1.hour, raw: true)
    project.broadcast_refresh_to(project, "transactions")
  end
end

private

def broadcast_interval
  ENV.fetch("TRANSACTION_BROADCAST_INTERVAL", 3).to_i
end
```

---

### 10. Add API Documentation Comments

**File:** `app/controllers/api/envelopes_controller.rb`

**Issue:** Missing documentation for public API endpoints.

**Recommended Solution:**

```ruby
# frozen_string_literal: true

# API controller for receiving Sentry protocol envelopes
#
# This controller is compatible with the Sentry SDK protocol and accepts
# error events and transaction data in the standard envelope format.
#
# @see https://develop.sentry.dev/sdk/envelopes/
class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /api/:project_id/envelope/
  #
  # Accepts a Sentry envelope containing error events or transaction data.
  # The endpoint supports multiple compression formats:
  # - gzip (Content-Encoding: gzip)
  # - brotli (Content-Encoding: br)
  # - zstandard (Content-Encoding: zstd)
  # - deflate (Content-Encoding: deflate)
  #
  # @param project_id [String] The project slug or ID
  # @header Content-Encoding [String] Optional compression format
  # @header X-Sentry-Auth [String] Sentry authentication header
  # @body [String] Sentry envelope in multiline format
  #
  # @return [200] Success - envelope queued for processing
  # @return [401] Unauthorized - invalid DSN credentials
  # @return [404] Not Found - project doesn't exist
  # @return [429] Too Many Requests - rate limit exceeded
  #
  # @example Sending an envelope
  #   POST /api/my-project/envelope/
  #   X-Sentry-Auth: Sentry sentry_key=abc123, sentry_version=7
  #   Content-Type: application/x-sentry-envelope
  #
  #   {"event_id":"abc-123","sent_at":"2025-10-22T00:00:00.000Z"}
  #   {"type":"event","length":1234}
  #   {"exception":{"values":[{"type":"RuntimeError","value":"Something broke"}]}}
  def create
    project = authenticate_project!
    return head :not_found unless project

    raw_body = request.body.read

    # Decompress based on Content-Encoding header
    # ... rest of implementation
  end

  private

  # Authenticates the request using DSN credentials
  #
  # @return [Project, nil] The authenticated project
  # @raise [DsnAuthenticationService::AuthenticationError] if auth fails
  def authenticate_project!
    DsnAuthenticationService.authenticate(request, params[:project_id])
  end
end
```

---

## Testing Recommendations

### Add Integration Tests

**File:** `test/system/error_tracking_test.rb`

```ruby
require "application_system_test_case"

class ErrorTrackingTest < ApplicationSystemTestCase
  setup do
    @project = projects(:one)
    @issue = issues(:one)
  end
  
  test "viewing issues list" do
    visit project_issues_path(@project.slug)
    
    assert_selector "h1", text: "Issues"
    assert_selector ".issue-card", count: @project.issues.open.count
  end
  
  test "viewing issue details and events" do
    visit project_issue_path(@project.slug, @issue)
    
    assert_text @issue.title
    assert_text "Total Events"
    assert_selector "#events-list"
  end
  
  test "resolving an issue" do
    visit project_issue_path(@project.slug, @issue)
    
    click_button "Resolve"
    
    assert_text "Issue marked as resolved"
    assert_selector ".bg-green-100", text: "Resolved"
  end
end
```

### Add Performance Tests

**File:** `test/performance/transaction_stats_test.rb`

```ruby
require "test_helper"

class TransactionStatsPerformanceTest < ActiveSupport::TestCase
  test "percentile calculation completes within 100ms for 1000 transactions" do
    project = projects(:one)
    
    # Create 1000 test transactions
    1000.times do |i|
      Transaction.create!(
        project: project,
        transaction_id: "perf-test-#{i}",
        transaction_name: "TestController#action",
        timestamp: Time.current,
        duration: rand(100..5000)
      )
    end
    
    time = Benchmark.realtime do
      Transaction.percentiles(24.hours.ago..Time.current, project_id: project.id)
    end
    
    assert_operator time * 1000, :<, 100, "Percentile calculation took #{time * 1000}ms, expected < 100ms"
  end
end
```

---

## Configuration Improvements

### Environment Variable Validation

**File:** `config/initializers/splat_config.rb`

```ruby
# Validate required environment variables at startup
module SplatConfig
  class ConfigurationError < StandardError; end
  
  def self.validate!
    # In production, require critical settings
    if Rails.env.production?
      required_vars = %w[
        SECRET_KEY_BASE
        SPLAT_HOST
        MCP_AUTH_TOKEN
      ]
      
      missing = required_vars.select { |var| ENV[var].blank? }
      
      if missing.any?
        raise ConfigurationError, 
          "Missing required environment variables: #{missing.join(', ')}"
      end
    end
    
    # Validate numeric values
    validate_numeric('API_RATE_LIMIT', min: 1, max: 10000, default: 100)
    validate_numeric('SPLAT_MAX_EVENT_LIFE_DAYS', min: 1, max: 365, default: 90)
    validate_numeric('TRANSACTION_BROADCAST_INTERVAL', min: 1, max: 60, default: 3)
  end
  
  def self.validate_numeric(key, min:, max:, default:)
    return unless ENV[key].present?
    
    value = ENV[key].to_i
    
    unless value.between?(min, max)
      Rails.logger.warn "#{key}=#{value} is outside valid range #{min}..#{max}, using default #{default}"
    end
  end
end

# Run validation at startup
SplatConfig.validate!
```

---

## Summary

These improvements are prioritized by impact and effort:

**Immediate (High Impact, Low Effort):**
- Add rate limiting
- Fix N+1 queries
- Replace magic numbers

**Short-term (High Impact, Medium Effort):**
- Extract TransactionStatsService
- Add time range concern
- Improve error handling

**Long-term (Medium Impact, Medium Effort):**
- Add integration tests
- Add partial indexes
- Enhance documentation

Each improvement is optional but recommended to enhance code quality, security, and maintainability.
