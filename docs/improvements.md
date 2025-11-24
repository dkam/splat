# Splat - Improvement Backlog

This document tracks suggested improvements, optimizations, and enhancements for Splat.

## High Priority

### 1. ✅ COMPLETED: Queue Depth Monitoring

**Problem:** If Solid Queue backs up, we won't know until we check the UI.

**Solution:** ✅ Enhanced `/_health` endpoint with `queue_status` field for Uptime Kuma monitoring.

**Implementation Status:** ✅ Completed
- Added `queue_status` field to health endpoint (`healthy`, `warning`, `critical`)
- Added `status` field to indicate overall system health (`ok` or `degraded`)
- Configurable thresholds via ENV vars (`QUEUE_WARNING_THRESHOLD=50`, `QUEUE_CRITICAL_THRESHOLD=100`)
- Documented Uptime Kuma JSON Query monitoring setup in README

**Uptime Kuma Configuration:**
```
Monitor Type: HTTP(s) - JSON Query
URL: https://splat.yourdomain.com/_health
JSON Path: $.queue_status
Expected Value: healthy
Alert When: Value is not equal to expected value
```

**Why this is better than a recurring job:**
- ✅ No additional background jobs needed
- ✅ Uptime Kuma polls at your preferred interval
- ✅ Uptime Kuma handles alerting (email, Slack, Discord, etc.)
- ✅ Historical tracking and uptime percentage built-in
- ✅ No code to maintain - just configuration
- ✅ Can monitor multiple thresholds (warning vs critical)

---

## Medium Priority

### 2. N+1 Query in Issue Events Display

**Location:** `app/views/issues/show.html.erb`

**Problem:** Loading events without eager loading the project association causes N+1 queries.

**Current code:**
```ruby
# app/controllers/issues_controller.rb
def show
  @events = @issue.events.recent.limit(50)
end
```

**Fix:**
```ruby
def show
  @events = @issue.events.includes(:project).recent.limit(50)
end
```

**Impact:** Reduces database queries from N+1 to 2 queries when displaying 50 events.

---

### 3. Missing Database Indexes

**Problem:** Several query patterns lack supporting indexes.

**Add these indexes:**
```ruby
# db/migrate/YYYYMMDDHHMMSS_add_performance_indexes.rb
class AddPerformanceIndexes < ActiveRecord::Migration[8.0]
  def change
    # Issues - searching by status and ordering by last_seen
    add_index :issues, [:status, :last_seen], order: { last_seen: :desc }

    # Events - filtering by timestamp with project
    add_index :events, [:project_id, :timestamp], order: { timestamp: :desc }

    # Transactions - filtering slow transactions
    add_index :transactions, [:project_id, :duration], order: { duration: :desc }
    add_index :transactions, [:transaction_name, :timestamp, :duration]

    # Transactions - environment filtering with timestamp
    add_index :transactions, [:environment, :timestamp, :duration]
  end
end
```

**Impact:** Faster queries on issues list, events filtering, and transaction analysis.

---

### 4. Optimize Percentile Calculations

**Location:** `app/models/project_performance.rb`

**Problem:** Loading all durations into memory to calculate percentiles is inefficient for large datasets.

**Current approach:**
```ruby
durations = transactions.pluck(:duration).sort
p95 = durations[(durations.size * 0.95).to_i]
```

**Better approach - Use database percentile functions:**
```ruby
# PostgreSQL
SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY duration) FROM transactions;

# SQLite (requires custom function)
# Or use sampling - take every Nth record
def calculate_p95(transactions)
  count = transactions.count
  return 0 if count.zero?

  # Use database offset to get approximate percentile
  transactions.order(:duration).offset((count * 0.95).to_i).limit(1).pick(:duration) || 0
end
```

**Note:** For SQLite, consider pre-calculating and caching percentiles hourly.

---

### 5. Cache Expensive Statistics

**Problem:** Performance dashboard recalculates statistics on every page load.

**Solution:** Cache aggregated stats, refresh periodically.

```ruby
# app/models/project_performance_cache.rb
class ProjectPerformanceCache
  def self.stats_for(project, time_range: 24.hours)
    cache_key = "perf_stats:#{project.id}:#{time_range.to_i}"

    Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      calculate_stats(project, time_range)
    end
  end

  private

  def self.calculate_stats(project, time_range)
    transactions = project.transactions.where('timestamp > ?', time_range.ago)

    {
      avg_duration: transactions.average(:duration).to_f.round,
      p95_duration: calculate_p95(transactions),
      p99_duration: calculate_p99(transactions),
      total_count: transactions.count,
      cached_at: Time.current
    }
  end
end
```

**Impact:** Reduces dashboard load time from ~500ms to ~50ms.

---

### 6. God Object - Transaction Model (278 lines)

**Location:** `app/models/transaction.rb`

**Problem:** Transaction model has too many responsibilities - parsing, validation, stats, broadcasting, percentile calculations.

**Current:** 278 lines handling everything.

**Recommendation:** Extract statistics and analysis to service objects.

```ruby
# app/services/transaction_stats_service.rb
class TransactionStatsService
  def initialize(scope, time_range: 24.hours)
    @transactions = scope.where('timestamp > ?', time_range.ago)
  end

  def percentiles
    durations = @transactions.pluck(:duration).sort
    return {} if durations.empty?

    {
      p50: durations[(durations.size * 0.50).to_i],
      p75: durations[(durations.size * 0.75).to_i],
      p95: durations[(durations.size * 0.95).to_i],
      p99: durations[(durations.size * 0.99).to_i]
    }
  end

  def stats_by_endpoint
    @transactions
      .group(:transaction_name)
      .select('transaction_name,
               AVG(duration) as avg_duration,
               COUNT(*) as count,
               MAX(duration) as max_duration,
               MIN(duration) as min_duration')
      .order('avg_duration DESC')
  end

  def slowest_transactions(limit: 20)
    @transactions.order(duration: :desc).limit(limit)
  end
end

# Usage in controller:
# app/controllers/transactions_controller.rb
def index
  stats_service = TransactionStatsService.new(
    Transaction.where(project: @project),
    time_range: parse_time_range
  )

  @percentiles = stats_service.percentiles
  @endpoints = stats_service.stats_by_endpoint
end
```

**Benefits:**
- Transaction model focuses on data, not analysis
- Service can be tested independently
- Easier to cache service results
- Reduces model complexity

**Impact:** Reduces Transaction model from 278 → ~150 lines

---

## Low Priority

### 7. Repeated Time Range Parsing

**Location:** Multiple controller actions

**Problem:** Time range parsing logic duplicated across `TransactionsController`.

**Current code:**
```ruby
# Repeated in index, slow, by_endpoint actions
def index
  @time_range = params[:time_range] || "24h"
  # ... conversion logic
end
```

**Fix - Extract to concern:**
```ruby
# app/controllers/concerns/time_rangeable.rb
module TimeRangeable
  extend ActiveSupport::Concern

  private

  def parse_time_range(param = nil)
    range_param = param || params[:time_range] || "24h"

    case range_param
    when "1h"  then 1.hour.ago
    when "24h" then 24.hours.ago
    when "7d"  then 7.days.ago
    when "30d" then 30.days.ago
    else 24.hours.ago
    end
  end

  def time_range_options
    {
      "1h" => "Last Hour",
      "24h" => "Last 24 Hours",
      "7d" => "Last 7 Days",
      "30d" => "Last 30 Days"
    }
  end
end

# app/controllers/transactions_controller.rb
class TransactionsController < ApplicationController
  include TimeRangeable

  def index
    @since = parse_time_range
    @transactions = Transaction.where('timestamp > ?', @since)
  end
end
```

---

### 7. Inefficient Broadcast Throttling

**Location:** `app/models/transaction.rb:263`

**Problem:** String comparison and parsing on cache reads.

**Current code:**
```ruby
def broadcast_transaction_update
  cache_key = "transaction_broadcast_#{project_id}"
  last_broadcast = Rails.cache.read(cache_key)
  last_broadcast = Time.parse(last_broadcast) if last_broadcast.is_a?(String)

  if last_broadcast.nil? || (Time.current - last_broadcast) >= broadcast_interval
    # ...
  end
end
```

**Fix - Store integers instead:**
```ruby
def broadcast_transaction_update
  cache_key = "transaction_broadcast_#{project_id}"
  last_broadcast_at = Rails.cache.read(cache_key).to_i
  now = Time.current.to_i

  if last_broadcast_at.zero? || (now - last_broadcast_at) >= broadcast_interval
    Rails.cache.write(cache_key, now, expires_in: 1.hour)
    project.broadcast_refresh_to(project, "transactions")
  end
end

private

def broadcast_interval
  5 # seconds
end
```

**Impact:** Minor - eliminates string parsing overhead.

---

### 8. Magic Numbers Throughout Codebase

**Problem:** Hard-coded values without explanation make code harder to understand and maintain.

**Examples:**

```ruby
# app/controllers/transactions_controller.rb:18
threshold = params[:threshold]&.to_i || 1000 # What does 1000 mean?

# app/models/transaction.rb:269
if last_broadcast.nil? || last_broadcast < throttle_interval.seconds.ago

# app/controllers/events_controller.rb
@events = Event.recent.limit(50) # Why 50?
```

**Recommendation:** Extract to named constants:

```ruby
# app/controllers/transactions_controller.rb
class TransactionsController < ApplicationController
  # Duration thresholds in milliseconds
  SLOW_TRANSACTION_THRESHOLD_MS = 1000
  VERY_SLOW_TRANSACTION_THRESHOLD_MS = 5000

  # Display limits
  DEFAULT_TRANSACTION_LIMIT = 100
  MAX_TRANSACTION_LIMIT = 1000

  def slow
    threshold = params[:threshold]&.to_i || SLOW_TRANSACTION_THRESHOLD_MS
    @transactions = Transaction
      .where('duration > ?', threshold)
      .order(duration: :desc)
      .limit(DEFAULT_TRANSACTION_LIMIT)
  end
end

# app/models/transaction.rb
class Transaction < ApplicationRecord
  # Broadcast throttling to avoid overwhelming Turbo Streams
  BROADCAST_INTERVAL_SECONDS = 3

  private

  def broadcast_transaction_update
    # ... use BROADCAST_INTERVAL_SECONDS
  end
end

# app/controllers/events_controller.rb
class EventsController < ApplicationController
  DEFAULT_EVENTS_PER_PAGE = 50
  MAX_EVENTS_PER_PAGE = 200

  def index
    limit = [params[:limit]&.to_i || DEFAULT_EVENTS_PER_PAGE, MAX_EVENTS_PER_PAGE].min
    @events = Event.recent.limit(limit)
  end
end
```

**Benefits:**
- Self-documenting code
- Easy to adjust without hunting through code
- Consistency across the application

**Impact:** Minimal performance impact, huge readability improvement

---

### 9. Duplicate Error Handling in MCP Controller

**Location:** `app/controllers/mcp/mcp_controller.rb`

**Problem:** Repeated error response structure throughout the controller.

**Current code:**
```ruby
# Repeated multiple times
render json: {
  jsonrpc: "2.0",
  error: { code: -32601, message: "Method not found" },
  id: @rpc_id
}

render json: {
  jsonrpc: "2.0",
  error: { code: -32602, message: "Invalid params" },
  id: @rpc_id
}

render json: {
  jsonrpc: "2.0",
  error: { code: -32603, message: "Internal error", data: { details: e.message } },
  id: @rpc_id
}
```

**Recommendation:** Extract to helper methods:

```ruby
# app/controllers/mcp/mcp_controller.rb
class Mcp::McpController < ApplicationController
  # JSON-RPC error codes
  PARSE_ERROR = -32700
  INVALID_REQUEST = -32600
  METHOD_NOT_FOUND = -32601
  INVALID_PARAMS = -32602
  INTERNAL_ERROR = -32603

  private

  def render_mcp_success(result)
    render json: {
      jsonrpc: "2.0",
      result: result,
      id: @rpc_id
    }
  end

  def render_mcp_error(code, message, data = nil)
    error = { code: code, message: message }
    error[:data] = data if data.present?

    render json: {
      jsonrpc: "2.0",
      error: error,
      id: @rpc_id
    }, status: :ok # JSON-RPC always returns 200
  end

  # Convenience methods for common errors
  def render_method_not_found(method_name)
    render_mcp_error(METHOD_NOT_FOUND, "Method '#{method_name}' not found")
  end

  def render_invalid_params(message)
    render_mcp_error(INVALID_PARAMS, message)
  end

  def render_internal_error(exception)
    render_mcp_error(
      INTERNAL_ERROR,
      "Internal error",
      { details: exception.message, backtrace: exception.backtrace.first(5) }
    )
  end
end

# Usage:
def handle_method
  case @method
  when "list_issues"
    render_mcp_success(list_issues_result)
  when "unknown_method"
    render_method_not_found(@method)
  else
    render_invalid_params("Missing required field 'query'")
  end
rescue => e
  render_internal_error(e)
end
```

**Benefits:**
- DRY - Don't Repeat Yourself
- Consistent error responses
- Easier to add error details/logging
- JSON-RPC constants documented in one place

**Impact:** Reduces controller size, improves maintainability

---

### 10. Simplify Version Detection

**Location:** `app/services/version_provider.rb`

**Current:** Git command execution on every call.

**Suggestion:** Cache version, only recalculate on deploy.

```ruby
# app/services/version_provider.rb
class VersionProvider
  class << self
    def current_version
      @current_version ||= detect_version
    end

    def reload!
      @current_version = nil
      current_version
    end

    private

    def detect_version
      # Try git first
      if File.exist?('.git')
        version = `git describe --tags --always 2>/dev/null`.strip
        return version unless version.empty?
      end

      # Fallback to VERSION file (create on deploy)
      if File.exist?('VERSION')
        return File.read('VERSION').strip
      end

      # Last resort
      "unknown"
    end
  end
end

# Create VERSION file on deploy
# bin/deploy
#!/bin/bash
git describe --tags --always > VERSION
# ... rest of deploy
```

---

## Nice to Have

### 11. Add Bullet Gem for N+1 Detection

**Purpose:** Automatically detect N+1 queries in development.

```ruby
# Gemfile
group :development do
  gem 'bullet'
end

# config/environments/development.rb
config.after_initialize do
  Bullet.enable = true
  Bullet.alert = true
  Bullet.bullet_logger = true
  Bullet.console = true
  Bullet.rails_logger = true
end
```

---

### 12. Add Request ID Tracking

**Problem:** Hard to correlate errors with specific requests across logs.

**Solution:** Add request_id to events and transactions.

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_request_ids.rb
class AddRequestIds < ActiveRecord::Migration[8.0]
  def change
    add_column :events, :request_id, :string
    add_column :transactions, :request_id, :string

    add_index :events, :request_id
    add_index :transactions, :request_id
  end
end

# Extract from Sentry payload
# app/jobs/process_event_job.rb
request_id: payload.dig('request', 'headers', 'X-Request-Id')
```

**Benefit:** Click on event → see related transaction performance.

---

## Questions / Decisions Needed

### Queue Depth Alert Frequency

**Options:**
1. **30 seconds** - Fast detection, might be noisy
2. **1 minute** - Good balance
3. **5 minutes** - Less noise, slower detection

**Recommendation:** Start with 1 minute, adjust based on experience.

### Alert Delivery Method

**Options:**
1. **Email** - Simple, works everywhere
2. **Uptime Kuma webhook** - Integrates with existing monitoring
3. **Slack/Discord** - Faster notification
4. **All of the above** - Configurable via ENV

**Recommendation:** Start with email, add webhook support later.

```bash
# .env options
ALERT_METHOD=email           # email, webhook, slack
ALERT_EMAIL=admin@example.com
ALERT_WEBHOOK_URL=https://uptime.kuma.pet/api/push/xyz
ALERT_SLACK_WEBHOOK=https://hooks.slack.com/services/xxx
```

### Percentile Calculation Strategy

**For SQLite:**
1. **In-memory** (current) - Simple but doesn't scale
2. **Database offset** - Fast approximation
3. **Pre-calculated** - Store hourly stats in separate table
4. **Sampling** - Calculate on subset of data

**Recommendation:**
- Stick with in-memory for now (simple)
- Add caching (5 minute TTL)
- If data grows >100k transactions, switch to pre-calculated stats

---

## Implementation Priority

**Now:**
1. ✅ ~~Queue depth monitoring~~ (COMPLETED - using Uptime Kuma)
2. Add missing database indexes (5 min)
3. Cache performance stats (15 min)

**Soon:**
1. Fix N+1 query (5 min)
2. Extract time range parsing (10 min)
3. Optimize broadcast throttling (5 min)
4. Extract magic numbers to constants (15 min)
5. Refactor MCP error handling (10 min)

**Later:**
1. Extract Transaction stats to service (30 min)
2. Bullet gem setup (2 min)
3. Request ID tracking (20 min)
4. Version caching (10 min)

**Total estimated time for remaining "Now" items: ~20 minutes**

---

## Notes

- Most improvements are micro-optimizations - current performance is probably fine
- Queue depth monitoring is the only critical one
- Database indexes should be added preemptively
- Everything else: measure first, optimize if needed

**Mantra:** Splat is designed for simplicity. Don't optimize until you have actual performance problems.
