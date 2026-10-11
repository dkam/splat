# frozen_string_literal: true

namespace :splat do
  namespace :schedule do
    desc "Hand config/schedule.yml to tuber (0.16+), which then runs the recurring jobs itself"
    task sync: :environment do
      # Run by bin/docker-entrypoint before the web server starts, so it never
      # fails the boot: a Splat that can't sync still serves, and the settings
      # page and /_health say the schedule isn't running.
      ::Tuber.configure { |c| c.connect_retries = 10 } # tuber may be starting alongside us

      result = Ingest::Schedule.sync
      puts "Schedule synced into tuber: #{result.added} added, #{result.changed} changed, " \
        "#{result.removed} removed, #{result.unchanged} unchanged"
    rescue Ingest::Schedule::Unsupported => e
      warn "Schedule not synced: #{e.message}. Run bin/scheduler (compose: --profile old-tuber) " \
        "to fire the recurring jobs, or upgrade tuber."
    rescue => e
      warn "Schedule not synced: #{e.class}: #{e.message}"
      Sentry.capture_exception(e, extra: {owner: Ingest::Schedule::OWNER})
    end
  end
end
