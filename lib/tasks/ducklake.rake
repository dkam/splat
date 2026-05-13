# frozen_string_literal: true

namespace :ducklake do
  desc "Bootstrap the DuckLake catalog (creates catalog, attaches lake, loads schema)"
  task setup: :environment do
    ApplicationDucklakeRecord.bootstrap!
    config = Rails.application.config.x.ducklake
    puts "DuckLake ready"
    puts "  catalog:   #{config[:catalog]}"
    puts "  storage:   #{config[:storage]}"
    puts "  data_path: #{config[:storage].to_s == 's3' ? "s3://#{config.dig(:s3, :bucket)}/#{config.dig(:s3, :prefix)}" : config[:data_path]}"
  end

  desc "Show DuckLake row counts"
  task status: :environment do
    ApplicationDucklakeRecord.bootstrap!
    %w[events transactions issues].each do |t|
      count = ApplicationDucklakeRecord.query("SELECT COUNT(*) AS n FROM #{t}").first["n"]
      puts "#{t.rjust(14)}: #{count}"
    end
  end

  desc "DESTRUCTIVE: drop and recreate the DuckLake catalog and data files (dev only)"
  task reset: :environment do
    raise "refusing to reset DuckLake in production" if Rails.env.production?

    config = Rails.application.config.x.ducklake
    catalog = Rails.root.join(config[:catalog])
    data_dir = Rails.root.join(config[:data_path]) if config[:storage].to_s != "s3"

    FileUtils.rm_f(catalog)
    FileUtils.rm_rf(data_dir) if data_dir
    puts "Removed #{catalog}"
    puts "Removed #{data_dir}" if data_dir

    Rake::Task["ducklake:setup"].invoke
  end

  # DROP the DuckLake mirror tables, recreate the schema, and re-mirror from
  # Postgres. Use when the mirror has accumulated catastrophic duplication
  # (e.g. an OOM-restart loop causing append-only multi_insert reprocessing)
  # and a fresh rebuild is cheaper than a per-row dedup.
  #
  # MUST be run with the ingest container and ducklake worker stopped — any
  # live mirror writes during the rebuild would land in the new tables and
  # confuse the row counts. Span data is lost (DuckLake-only, no Postgres
  # source); fresh transactions repopulate spans on resume.
  #
  # Gated by I_KNOW_WHAT_IM_DOING=yes to prevent accidental invocation.
  desc "DESTRUCTIVE: drop DuckLake mirror tables and re-mirror from Postgres"
  task rebuild: :environment do
    unless ENV["I_KNOW_WHAT_IM_DOING"] == "yes"
      abort <<~MSG
        Refusing to run. This task drops all DuckLake mirror tables and
        re-mirrors from Postgres. Spans are lost (DuckLake-only).

        Stop the ingest and ducklake containers, then run:
          I_KNOW_WHAT_IM_DOING=yes bin/rails ducklake:rebuild
      MSG
    end

    ApplicationDucklakeRecord.bootstrap!
    conn = ApplicationDucklakeRecord.connection

    # One-shot memory ergonomics: bigger budget for the bulk inserts + cleanup,
    # skip ordered output (we don't care), single-threaded keeps peak low.
    ApplicationDucklakeRecord.execute("SET memory_limit = '3GB'")
    ApplicationDucklakeRecord.execute("SET preserve_insertion_order = false")
    ApplicationDucklakeRecord.execute("SET threads = 1")

    # Drop in reverse dependency order. The CREATE IF NOT EXISTS in
    # load_schema! and the ALTER ADD COLUMN in ensure_columns! are idempotent,
    # so rerunning the rake on an already-emptied lake is safe.
    puts "Dropping tables..."
    %w[spans transactions events issues].each do |t|
      print "  drop #{t}... "
      ApplicationDucklakeRecord.execute("DROP TABLE IF EXISTS #{t}")
      puts "ok"
    end

    puts "Recreating schema..."
    ApplicationDucklakeRecord.send(:load_schema!, conn)
    ApplicationDucklakeRecord.send(:ensure_columns!, conn)
    ApplicationDucklakeRecord.send(:apply_partitioning!, conn)

    # Backfill in forward dependency order (issues before events for the
    # issue_id FK reference). Batch size stays well above
    # data_inlining_row_limit (50) so every INSERT bypasses inline and writes
    # parquet directly — fewer catalog snapshots, nicely-sized files.
    mirrors = [
      [Issue,       DuckLake::Issue,       1000],
      [Event,       DuckLake::Event,       5000],
      [Transaction, DuckLake::Transaction, 5000]
    ]

    mirrors.each do |source, mirror, batch_size|
      total = source.count
      puts "Backfilling #{source.name} (#{total} rows, batch #{batch_size})..."
      done = 0
      t0 = Time.current
      source.find_in_batches(batch_size: batch_size) do |group|
        mirror.multi_insert(group.map(&:to_ducklake_row))
        done += group.size
        printf "\r  %d/%d", done, total
      end
      puts " (#{(Time.current - t0).round(1)}s)"
    end

    puts "Expiring snapshots and cleaning up old files..."
    ApplicationDucklakeRecord.query(
      "CALL ducklake_expire_snapshots('splat_lake', older_than => NOW())"
    )
    cleanup = ApplicationDucklakeRecord.query(
      "CALL ducklake_cleanup_old_files('splat_lake', dry_run => false)"
    )
    puts "  cleanup: #{cleanup.inspect}"

    puts
    puts "Final row counts:"
    %w[issues events transactions spans].each do |t|
      c = ApplicationDucklakeRecord.query("SELECT count(*) AS n FROM #{t}").first["n"]
      puts "  #{t.rjust(14)}: #{c}"
    end
  end
end
