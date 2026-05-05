-- DuckLake schema for Splat analytics.
--
-- Mirrors the AR schema in db/schema.rb but typed for DuckDB columnar storage.
-- Loaded by ApplicationDucklakeRecord on boot (idempotent CREATE IF NOT EXISTS),
-- or explicitly via `bin/rails ducklake:setup`.
--
-- Tables are namespaced inside the lake (ATTACHed as `splat_lake` in the
-- initializer); fully-qualified names are written by the application code.

CREATE TABLE IF NOT EXISTS events (
  id              BIGINT,
  event_id        VARCHAR NOT NULL,
  project_id      INTEGER NOT NULL,
  issue_id        BIGINT,
  timestamp       TIMESTAMP NOT NULL,
  duration        INTEGER DEFAULT 0,
  environment     VARCHAR,
  exception_type  VARCHAR,
  exception_value VARCHAR,
  fingerprint     VARCHAR,
  message         VARCHAR,
  platform        VARCHAR,
  release         VARCHAR,
  sdk_name        VARCHAR,
  sdk_version     VARCHAR,
  server_name     VARCHAR,
  transaction_name VARCHAR,
  payload         JSON,
  created_at      TIMESTAMP,
  updated_at      TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transactions (
  id               BIGINT,
  transaction_id   VARCHAR NOT NULL,
  project_id       INTEGER NOT NULL,
  timestamp        TIMESTAMP NOT NULL,
  transaction_name VARCHAR NOT NULL,
  op               VARCHAR,
  duration         INTEGER NOT NULL,
  db_time          INTEGER,
  view_time        INTEGER,
  environment      VARCHAR,
  release          VARCHAR,
  server_name      VARCHAR,
  http_method      VARCHAR,
  http_status      VARCHAR,
  http_url         VARCHAR,
  tags             JSON,
  measurements     JSON,
  created_at       TIMESTAMP,
  updated_at       TIMESTAMP
);

-- Issues are mutable in AR; we record snapshots in DuckLake on each event
-- ingest. Read paths that care about the latest state should pick the row
-- with MAX(updated_at) per (project_id, fingerprint).
CREATE TABLE IF NOT EXISTS issues (
  id             BIGINT,
  project_id     INTEGER NOT NULL,
  fingerprint    VARCHAR NOT NULL,
  title          VARCHAR NOT NULL,
  exception_type VARCHAR,
  status         INTEGER DEFAULT 0,
  count          INTEGER DEFAULT 0,
  first_seen     TIMESTAMP NOT NULL,
  last_seen      TIMESTAMP NOT NULL,
  created_at     TIMESTAMP,
  updated_at     TIMESTAMP
);

-- Partitioning (year+month of timestamp on events/transactions) is applied
-- by ApplicationDucklakeRecord#apply_partitioning! at boot, not here —
-- DuckLake records each ALTER as a new metadata snapshot, so re-running
-- this file on every boot would grow the catalog unnecessarily.
