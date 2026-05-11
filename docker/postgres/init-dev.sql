-- Dev-only init: runs once on first container start against an empty data
-- directory. Creates the logical DBs Rails + DuckLake need beyond the
-- default `splat_development` (which POSTGRES_DB already created).
--
-- For test DBs, just run `bin/rails db:create RAILS_ENV=test` plus the
-- catalog DB manually:
--   psql -h localhost -U splat -c "CREATE DATABASE splat_test_catalog OWNER splat;"

CREATE DATABASE splat_development_cache OWNER splat;
CREATE DATABASE splat_development_cable OWNER splat;
CREATE DATABASE splat_catalog_development OWNER splat;
