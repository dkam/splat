require "test_helper"
require "fugit"

# config/schedule.yml is the only place Splat says *when* heavy maintenance
# runs, and it is read by a process running on a UTC host with Rails'
# config.time_zone left at its UTC default. A bare cron hour there therefore
# means UTC, which is not what anyone reading "0 2" is picturing.
#
# Melbourne is UTC+10 (AEST) or UTC+11 (AEDT), so `cron 0 2 * * *` fired at
# midday Melbourne — Maintenance::RetentionJob holds write locks on
# transactions_spans for 3+ hours, and it was spending them across the middle
# of the working day. storage_stats_deep was worse: its own comment records a
# run from 03:40 to 11:34 UTC, i.e. 13:40 to 21:34 Melbourne.
#
# These tests pin the intent ("2am where the users are") rather than the
# literal string, because the string is exactly what was wrong.
class Ingest::SchedulerTest < ActiveSupport::TestCase
  ZONE = "Australia/Melbourne"

  # Jobs pinned to an hour of the night. Interval and hourly jobs are omitted
  # deliberately: "every 10m" and "cron 5 * * * *" fire the same number of
  # times whatever the zone, so naming one would be noise.
  NIGHTLY = %w[data_retention logs_fts_optimize storage_stats_deep dictionary_drift].freeze

  def schedule
    @schedule ||= YAML.load_file(Ingest::Scheduler::SCHEDULE_PATH)
  end

  def cron_for(name)
    entry = schedule.fetch(name)
    expr = entry.fetch("schedule").sub(/\Acron\s+/, "")
    Fugit::Cron.parse(expr) || flunk("#{name}: #{expr.inspect} is not a parseable cron line")
  end

  def local_hour(name)
    cron_for(name).next_time.to_utc_time.in_time_zone(ZONE).hour
  end

  test "every nightly maintenance job names its timezone" do
    NIGHTLY.each do |name|
      assert_equal ZONE, cron_for(name).zone,
        "#{name} has no timezone, so its hour silently means UTC on a UTC host"
    end
  end

  test "data_retention runs at 2am Melbourne, not midday" do
    assert_equal 2, local_hour("data_retention")
  end

  test "the nightly cluster stays in the small hours, Melbourne time" do
    NIGHTLY.each do |name|
      assert_includes 0..4, local_hour(name),
        "#{name} runs at #{local_hour(name)}:00 Melbourne — heavy maintenance belongs overnight"
    end
  end

  test "logs_fts_optimize still follows data_retention" do
    # Its comment depends on this: the night's deletes only leave delete-markers
    # in logs_fts, and the merge is scheduled after retention so they start
    # getting merged away the same night. Moving the cluster must not reorder it.
    # Both measured from the same reference instant — comparing each cron's
    # next occurrence from "now" says nothing when now falls between them.
    from = Time.utc(2026, 9, 11, 14, 0, 0) # midnight, Melbourne
    retention = cron_for("data_retention").next_time(from).to_utc_time
    optimize = cron_for("logs_fts_optimize").next_time(from).to_utc_time

    assert_operator optimize, :>, retention,
      "logs_fts_optimize must still run after data_retention"
    assert_operator optimize - retention, :<, 2.hours,
      "and close enough behind it to be the same night's work"
  end

  test "the schedule survives a DST changeover in both directions" do
    # Melbourne shifts on the first Sunday of October (2am -> 3am, so 2am does
    # not occur) and the first Sunday of April (3am -> 2am, so it occurs twice).
    # Whatever fugit decides to do, it must keep producing valid future times
    # rather than raising or stalling.
    cron = cron_for("data_retention")
    [Time.utc(2026, 10, 3), Time.utc(2027, 4, 3)].each do |before_change|
      t = cron.next_time(before_change)
      assert t, "no occurrence after #{before_change}"
      assert_operator t.to_utc_time, :>, before_change
      assert t.to_utc_time < before_change + 8.days, "next occurrence is implausibly far out: #{t}"
    end
  end

  test "interval and hourly jobs are left zone-free on purpose" do
    %w[monitor_evaluation wal_checkpoint histogram_rollup storage_stats].each do |name|
      expr = schedule.fetch(name).fetch("schedule")
      refute_includes expr, ZONE,
        "#{name} fires on an interval or hourly — a timezone would only add noise"
    end
  end
end
