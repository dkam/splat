-- Bootstrap script run on first Postgres container start. Mounted into
-- /docker-entrypoint-initdb.d/ — postgres only runs these on an *empty*
-- data directory, so this is idempotent only across fresh deploys, not
-- re-runs against an existing cluster.
--
-- Creates the three Rails logical DBs (cache + cable + ops) plus the
-- DuckLake catalog DB. The default `splat` database from POSTGRES_DB
-- env is what Rails treats as `splat`. The user is created by the
-- postgres image from POSTGRES_USER / POSTGRES_PASSWORD.

CREATE DATABASE splat_cache OWNER splat;
CREATE DATABASE splat_cable OWNER splat;
CREATE DATABASE splat_catalog OWNER splat;
