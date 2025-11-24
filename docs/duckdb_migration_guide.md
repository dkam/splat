# DuckDB Migration Guide

## Overview
The `FastMigrateToDuckdbJob` uses DuckDB's SQLite extension for ultra-fast data migration from SQLite to DuckDB.

## Configuration

### Environment Variables
```bash
# Override default cutoff days (environment-specific defaults apply)
DUCKDB_MIGRATION_CUTOFF_DAYS=14
```

### Default Cutoff Days by Environment
- **Development**: 1 day
- **Test**: 1 day
- **Production**: 7 days

### Database Path
Automatically detected from `config/database.yml`:
```yaml
production:
  primary:
    database: storage/production.sqlite3  # → Rails.root/storage/production.sqlite3
```

## Usage

### 1. Manual Migration
```ruby
# Migrate both transactions and events
FastMigrateToDuckdbJob.perform_now('all')

# Migrate only transactions
FastMigrateToDuckdbJob.perform_now('transactions')

# Migrate only events
FastMigrateToDuckdbJob.perform_now('events')
```

### 2. Custom Cutoff Days
```ruby
# Migrate data older than 14 days
FastMigrateToDuckdbJob.perform_now('all', 14)

# Migrate transactions older than 30 days
FastMigrateToDuckdbJob.perform_now('transactions', 30)

# Migrate events older than 3 days
FastMigrateToDuckdbJob.perform_now('events', 3)
```

### 3. Environment Variable Override
```bash
# Set environment variable
export DUCKDB_MIGRATION_CUTOFF_DAYS=14

# Run with environment variable
FastMigrateToDuckdbJob.perform_now('all')
```

## Scheduled Migration

The migration is scheduled to run daily:
- **Development/Production**: 3am every day
- **Cleanup runs at**: 2am every day (before migration)

Configuration in `config/recurring.yml`:
```yaml
production:
  migrate_to_duckdb:
    class: "FastMigrateToDuckdbJob"
    schedule: at 3am every day
```

## Performance

### Expected Performance
| Dataset | Old Method | New Method | Speed Improvement |
|---------|------------|------------|------------------|
| 5M transactions | ~60 minutes | ~2-5 minutes | **10-30x faster** |
| 84k events | ~10 minutes | ~30 seconds | **20-50x faster** |

### How It Works
1. **INSTALL sqlite** - Load DuckDB SQLite extension
2. **ATTACH database** - Connect to SQLite database
3. **CREATE TABLE AS SELECT** - Direct data transfer
4. **Index creation** - Create performance indexes
5. **SQLite cleanup** - Delete migrated data

## Safety Features

- ✅ **Transactional**: Migration is atomic
- ✅ **Verification**: Data counts verified before/after
- ✅ **Rollback safe**: Only deletes from SQLite after successful copy
- ✅ **Error handling**: Comprehensive error logging and retry logic

## Monitoring

### Check Migration Status
```ruby
# Check DuckDB database
DuckdbManager.database_ready?
DuckdbManager.statistics

# Check remaining data in SQLite
Event.count
Transaction.count
```

### Log Monitoring
```bash
# Production logs
tail -f log/production.log | grep "Fast migration"

# Look for:
# - "Starting ultra-fast [transactions|events] migration"
# - "Successfully migrated X [transactions|events] to DuckDB"
# - "Fast migration completed in X seconds"
```

## Troubleshooting

### Common Issues

1. **SQLite extension not available**
   ```
   Error: extension "sqlite" not found
   ```
   **Solution**: Ensure DuckDB version includes SQLite extension

2. **Database path not found**
   ```
   Error: no such file or directory: [path]
   ```
   **Solution**: Check `config/database.yml` configuration

3. **Permission errors**
   ```
   Error: permission denied for database
   ```
   **Solution**: Check file permissions for SQLite database

### Debug Commands
```ruby
# Test SQLite extension
DuckdbManager.with_connection do |conn|
  conn.execute("INSTALL sqlite")
  conn.execute("LOAD sqlite")
  puts "SQLite extension working!"
end

# Test database path
puts FastMigrateToDuckdbJob.new.send(:sqlite_database_path)

# Test cutoff calculation
puts FastMigrateToDuckdbJob.new.send(:migration_cutoff_days)
```