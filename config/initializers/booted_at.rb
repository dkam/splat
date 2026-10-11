# frozen_string_literal: true

# When this process started. Ingest::ScheduleStatus counts from here for a
# scheduled job with no run on record, so an instance where nothing has ever
# run the schedule still goes late, rather than staying "not run yet" forever.
Rails.application.config.x.booted_at = Time.current
