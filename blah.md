  # Splat - Lightweight Error Tracker Project Summary                                                                                                                  │
│                                                                                                                                                                        │
│   ## Overview                                                                                                                                                          │
│   Building "Splat" - a simple, single-tenant error tracking service to replace Glitchtip (which has performance issues with 4000+ job queue backlog and 5-15 minute    │
│   event delays).                                                                                                                                                       │
│                                                                                                                                                                        │
│   ## Design Goals                                                                                                                                                      │
│   - **No multi-tenancy complexity**: No users, teams, or project management                                                                                            │
│   - **Single DSN**: All events go to one place                                                                                                                         │
│   - **Fast**: No Celery/Python overhead like Glitchtip                                                                                                                 │
│   - **Simple**: Just receive events → store → display                                                                                                                  │
│                                                                                                                                                                        │
│   ## Technology Stack                                                                                                                                                  │
│   - **Rails 8** application                                                                                                                                            │
│   - **SQLite** for storage (fitting with Solid* ecosystem)                                                                                                             │
│   - **Solid Queue** for async processing (grouping, notifications)                                                                                                     │
│   - **Solid Cache** for counters/stats                                                                                                                                 │
│   - **Solid Cable** for real-time updates                                                                                                                              │
│   - **Phlex** components for UI                                                                                                                                        │
│                                                                                                                                                                        │
│   ## Sentry Protocol Basics                                                                                                                                            │
│   **DSN Format**: `{PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PROJECT_ID}`                                                                                                      │
│   - Example: `https://3b8010b3548a45b4a9ff81e57f3ad07a@splat.booko.info/1`                                                                                             │
│   - PUBLIC_KEY is just a random auth token (not actual cryptography)                                                                                                   │
│   - PROJECT_ID routes to different projects (we'll use 1 or ignore it)                                                                                                 │
│                                                                                                                                                                        │
│   **Event Types** (sent via POST to `/api/{project_id}/envelope/`):                                                                                                    │
│   1. **Error events** - Exceptions, error messages (REQUIRED)                                                                                                          │
│   2. **Transaction events** - Performance traces (OPTIONAL - can skip for MVP)                                                                                         │
│                                                                                                                                                                        │
│   **Envelope Format**:                                                                                                                                                 │
│   ```                                                                                                                                                                  │
│   {headers}\n                                                                                                                                                          │
│   {item_headers}\n                                                                                                                                                     │
│   {item_payload}\n                                                                                                                                                     │
│   ```                                                                                                                                                                  │
│                                                                                                                                                                        │
│   ## Core Architecture                                                                                                                                                 │
│                                                                                                                                                                        │
│   ### Database Schema (SQLite)                                                                                                                                         │
│   ```ruby                                                                                                                                                              │
│   # events - Raw events from Sentry protocol                                                                                                                           │
│   - id, event_id (uuid), timestamp, platform, sdk_name, sdk_version                                                                                                    │
│   - exception_type, exception_value, message                                                                                                                           │
│   - environment, release, server_name                                                                                                                                  │
│   - fingerprint (array), transaction (controller/action)                                                                                                               │
│   - payload (jsonb - full event data)                                                                                                                                  │
│   - created_at                                                                                                                                                         │
│                                                                                                                                                                        │
│   # issues - Grouped events by fingerprint                                                                                                                             │
│   - id, fingerprint, title, exception_type                                                                                                                             │
│   - first_seen, last_seen, count, status (unresolved/resolved/ignored)                                                                                                 │
│   - created_at, updated_at                                                                                                                                             │
│                                                                                                                                                                        │
│   # occurrences - Links events to issues                                                                                                                               │
│   - id, issue_id, event_id                                                                                                                                             │
│   ```                                                                                                                                                                  │
│                                                                                                                                                                        │
│   ### Authentication Options                                                                                                                                           │
│   1. **No auth** - Accept everything (simplest for single tenant)                                                                                                      │
│   2. **Shared secret** - Check `ENV['SPLAT_KEY']` matches DSN public_key                                                                                               │
│   3. **Ignore it** - Accept any key value                                                                                                                              │
│                                                                                                                                                                        │
│   ### API Endpoints                                                                                                                                                    │
│   ```ruby                                                                                                                                                              │
│   # POST /api/:project_id/envelope/                                                                                                                                    │
│   # - Parse Sentry envelope format                                                                                                                                     │
│   # - Extract event payload                                                                                                                                            │
│   # - Queue for processing via Solid Queue                                                                                                                             │
│   # - Return 200 OK                                                                                                                                                    │
│                                                                                                                                                                        │
│   # GET /_health/                                                                                                                                                      │
│   # - Return basic health check                                                                                                                                        │
│   # - Include queue depth, event count                                                                                                                                 │
│   ```                                                                                                                                                                  │
│                                                                                                                                                                        │
│   ### Processing Pipeline                                                                                                                                              │
│   1. **Receive** envelope via POST                                                                                                                                     │
│   2. **Parse** envelope format → extract event JSON                                                                                                                    │
│   3. **Queue** processing job (Solid Queue)                                                                                                                            │
│   4. **Process** async:                                                                                                                                                │
│      - Generate fingerprint (group similar errors)                                                                                                                     │
│      - Find or create Issue                                                                                                                                            │
│      - Store Event                                                                                                                                                     │
│      - Update Issue counts/timestamps                                                                                                                                  │
│   5. **Broadcast** updates via Solid Cable (optional)                                                                                                                  │
│                                                                                                                                                                        │
│   ## Current Context - Why Building This                                                                                                                               │
│                                                                                                                                                                        │
│   ### Glitchtip Issues Discovered                                                                                                                                      │
│   - 4,346 tasks queued in Celery (should be near-zero)                                                                                                                 │
│   - 5-15 minute delay for events to appear in UI                                                                                                                       │
│   - Worker config: `CELERY_WORKER_AUTOSCALE=1,3` (too slow)                                                                                                            │
│   - Health endpoints useless - return "ok" even with massive backlog                                                                                                   │
│   - No built-in monitoring/alerting for queue depth                                                                                                                    │
│                                                                                                                                                                        │
│   ### Temporary Fixes Applied                                                                                                                                          │
│   1. Reduced Sentry `traces_sample_rate` from 0.1 → 0.05 (or lower)                                                                                                    │
│   2. Fixed broken `before_send` callback that was crashing on exceptions                                                                                               │
│   3. Created custom monitoring script for Uptime Kuma                                                                                                                  │
│                                                                                                                                                                        │
│   ### Multi-Database Issue (Separate from Splat)                                                                                                                       │
│   - Attempted to enable Rails read/write splitting (primary + replica)                                                                                                 │
│   - Discovered History model writes during GET requests cause `ActiveRecord::ReadOnlyError`                                                                            │
│   - Database selector middleware temporarily disabled                                                                                                                  │
│   - Need to wrap History writes in `connected_to(role: :writing)` blocks                                                                                               │
│                                                                                                                                                                        │
│   ## Next Steps for Splat                                                                                                                                              │
│   1. Generate new Rails 8 app with SQLite                                                                                                                              │
│   2. Set up Solid Queue/Cache/Cable                                                                                                                                    │
│   3. Implement envelope parsing endpoint                                                                                                                               │
│   4. Create basic event storage                                                                                                                                        │
│   5. Build simple Phlex UI for viewing issues                                                                                                                          │
│   6. Deploy and point Booko's Sentry DSN at it                                                                                                                         │
│                                                                                                                                                                        │
│   ## Reference                                                                                                                                                         │
│   - Sentry Protocol: https://develop.sentry.dev/sdk/envelopes/                                                                                                         │
│   - Expected complexity: ~500 lines for basic functionality                                                                                                            │
│   - Name: "Splat" (bug squashing + Ruby splat operator)                                                                                                                │
│   EOF                                                                                                                                                                  │
│   cat << 'EOF'                                                                                                                                                         │
│                                                                                                                                                                        │
│   ## Key Files Modified (Booko Codebase)                                                                                                                               │
│   - config/initializers/sentry.rb - Fixed before_send callback, reduced trace sampling                                                                                 │
│   - config/environments/production.rb - Database selector middleware (commented out)                                                                                   │
│   - app/models/history.rb - Needs fixing for read/write splitting
