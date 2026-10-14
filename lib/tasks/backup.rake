# Copies of Splat's databases — see DatabaseBackup and README, Backup.
namespace :splat do
  namespace :backup do
    desc "Snapshot each database with VACUUM INTO, into DIR (default storage/backups/<UTC time>)"
    task :snapshot, [:dir] => :environment do |_, args|
      dir = args[:dir].presence || Rails.root.join("storage", "backups", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
      DatabaseBackup.snapshot(dir, log: ->(line) { puts line })
    rescue DatabaseBackup::Exists => e
      abort "Not overwriting a snapshot — #{e.message}"
    end

    desc "Bring a copy of each database in DIR up to date (default storage/backups/current): " \
      "sqlite3_rsync where installed and there's a copy, VACUUM INTO otherwise"
    task :sync, [:dir] => :environment do |_, args|
      dir = args[:dir].presence || Rails.root.join("storage", "backups", "current")
      puts "sqlite3_rsync isn't installed: each copy is made afresh with VACUUM INTO" unless DatabaseBackup.rsync_path
      DatabaseBackup.sync(dir, log: ->(line) { puts line })
    end
  end
end
