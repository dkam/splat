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
end
