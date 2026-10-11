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

  # --- What the scheduler does with tuber's reply -----------------------------

  # Registers one real entry and fires it the way rufus would, with tuber's
  # reply stubbed. Returns what was put and anything reported to Sentry.
  def fire(name, reply)
    scheduler = Ingest::Scheduler.new
    scheduler.send(:register, Ingest::Schedule.entry(name))
    puts_made = []
    reports = []
    with_stub(Ingest::Tuber, :put, ->(tube, payload, **opts) { puts_made << [tube, payload, opts] and reply }) do
      with_stub(Sentry, :capture_message, ->(message, **opts) { reports << [message, opts] }) do
        scheduler.instance_variable_get(:@rufus).jobs.first.call
      end
    end
    [puts_made, reports]
  ensure
    scheduler&.stop!
  end

  # 2026-09-09: HistogramRollupJob buried on lock contention. A buried job keeps
  # its idp: key, so every hourly put after it got `INSERTED <id> BURIED` and
  # created nothing — for three days, while the scheduler logged "firing". The
  # reply said so; nothing read it.
  test "a put suppressed by a buried job is reported, every time" do
    _puts, reports = fire("histogram_rollup", {status: "INSERTED", id: "812", state: "BURIED"})

    assert_equal 1, reports.size, "a run lost to a buried job must reach Sentry"
    message, opts = reports.first
    assert_match "histogram_rollup", message
    assert_equal :error, opts[:level]
    assert_equal ["scheduler", "suppressed_by_buried", "histogram_rollup"], opts[:fingerprint]
    assert_equal "812", opts[:extra][:buried_job_id]
  end

  test "a put deduped against a run still in flight, or by the cooldown, is not an alarm" do
    %w[READY RESERVED DELAYED DELETED].each do |state|
      _puts, reports = fire("histogram_rollup", {status: "INSERTED", id: "812", state: state})
      assert_empty reports, "#{state}: the key doing its job is routine"
    end
  end

  test "a fresh insert is not an alarm" do
    _puts, reports = fire("histogram_rollup", {status: "INSERTED", id: "813"})

    assert_empty reports
  end

  # --- Firing safely from more than one scheduler -----------------------------

  test "every entry carries an idp: key" do
    missing = schedule.reject { |_name, entry| entry["idp"] }.keys
    assert_empty missing, "without a key, a second scheduler doubles these: #{missing.join(", ")}"
  end

  test "each put keeps deduplicating for a cooldown after the job is deleted" do
    # Without a cooldown the key goes with the job, so a second scheduler's put
    # a moment after a fast job finished creates a duplicate.
    puts_made, _reports = fire("monitor_evaluation", {status: "INSERTED", id: "1"})

    assert_equal ["monitor_evaluation", Ingest::Scheduler::IDP_COOLDOWN], puts_made.first.last[:idp]
  end

  test "each put names its entry, so the worker that runs it can record the run" do
    puts_made, _reports = fire("storage_stats_deep", {status: "INSERTED", id: "1"})

    tube, payload, _opts = puts_made.first
    assert_equal "splat.maintenance", tube
    assert_equal({class: "Maintenance::StorageStatsJob", args: ["deep"], schedule: "storage_stats_deep"}, payload)
  end

  test "every entry is a cron line, so every scheduler fires it on the same second" do
    # rufus's `every 60s` counts from when each scheduler started, so two of
    # them fire at different offsets and no short cooldown can merge them.
    schedule.each do |name, entry|
      assert_match(/\Acron /, entry["schedule"], "#{name} is not a cron line")
    end
  end

  test "the cooldown is shorter than the gap between any entry's runs" do
    from = Time.utc(2026, 9, 11)
    schedule.each_key do |name|
      first = cron_for(name).next_time(from)
      gap = cron_for(name).next_time(first).to_utc_time - first.to_utc_time
      assert_operator Ingest::Scheduler::IDP_COOLDOWN, :<, gap,
        "#{name}'s cooldown would swallow its own next run"
    end
  end

  test "interval and hourly jobs are left zone-free on purpose" do
    %w[monitor_evaluation wal_checkpoint histogram_rollup storage_stats].each do |name|
      expr = schedule.fetch(name).fetch("schedule")
      refute_includes expr, ZONE,
        "#{name} fires on an interval or hourly — a timezone would only add noise"
    end
  end

  # --- Tuber's scheduler, or this process's -----------------------------------

  SYNCED = Tuber::Schedules::SyncResult.new(9, 0, 0, 0)
  HELD = [["splat", "data_retention"], ["splat", "monitor_evaluation"]].freeze
  OLD_TUBER = Tuber::UnknownCommandError.new("UNKNOWN_COMMAND", "schedule-list splat")

  # A stand-in producer whose tuber answers schedule-list with whatever
  # +answers+ yields next: a list, or an error to raise.
  def producer_answering(answers)
    schedules = Object.new
    schedules.define_singleton_method(:list) do |_owner|
      answer = answers.call
      answer.is_a?(Exception) ? raise(answer) : answer
    end
    conn = Object.new
    conn.define_singleton_method(:schedules) { schedules }
    conn
  end

  # Runs +block+ against a tuber holding +held+ (or raising it), with
  # Schedule.sync answering +sync+. Returns the block's result, the syncs made
  # and what reached Sentry.
  def against_tuber(held, sync: -> { SYNCED })
    syncs = 0
    reports = []
    answers = held.respond_to?(:call) ? held : -> { held }
    conn = producer_answering(answers)
    result = with_stub(Ingest::Tuber, :with_producer, ->(&blk) { blk.call(conn) }) do
      with_stub(Ingest::Schedule, :sync, -> { syncs += 1 and sync.call }) do
        with_stub(Sentry, :capture_exception, ->(e, **opts) { reports << e }) { yield }
      end
    end
    [result, syncs, reports]
  end

  def choose(held, sync: -> { SYNCED })
    scheduler = Ingest::Scheduler.new
    scheduler.define_singleton_method(:sleep) { |*| nil }
    against_tuber(held, sync:) { scheduler.choose_mode }
  ensure
    scheduler&.stop!
  end

  test "on a tuber already holding the schedule, it leaves it alone and idles" do
    mode, syncs, reports = choose(HELD)

    assert_equal :idle, mode
    assert_equal 0, syncs, "the web container syncs on boot; a scheduler mustn't overwrite that"
    assert_empty reports
  end

  test "on a tuber with schedules but none of Splat's, it puts them there, then idles" do
    mode, syncs, _reports = choose([])

    assert_equal :idle, mode
    assert_equal 1, syncs
  end

  test "on a tuber without schedules it fires them itself" do
    mode, syncs, _reports = choose(OLD_TUBER)

    assert_equal :rufus, mode
    assert_equal 0, syncs
  end

  test "a set tuber refuses is reported, and fired from here so this release's schedule runs" do
    refused = Tuber::ScheduleSyncError.new("BAD_SCHEDULE", "schedule-put x", owner: "splat", entry: "x")
    mode, _syncs, reports = choose([], sync: -> { raise refused })

    assert_equal :rufus, mode
    assert_equal [refused], reports
  end

  test "it waits for an unreachable tuber rather than guessing" do
    attempts = 0
    mode, _syncs, _reports = choose(-> {
      attempts += 1
      raise Tuber::NotConnected, "refused" if attempts < 3
      HELD
    })

    assert_equal :idle, mode
    assert_equal 3, attempts
  end

  # A scheduler firing the schedule itself, as on an old tuber.
  def firing_scheduler
    scheduler = Ingest::Scheduler.new
    scheduler.instance_variable_set(:@mode, :rufus)
    scheduler.send(:register_jobs)
    scheduler
  end

  test "firing the schedule itself on an old tuber, it says so every tick" do
    scheduler = firing_scheduler
    Rails.cache.delete(Ingest::Scheduler::HEARTBEAT_KEY)

    against_tuber(OLD_TUBER) { scheduler.tick }

    assert_equal :rufus, scheduler.mode
    refute_empty scheduler.instance_variable_get(:@rufus).jobs
    assert Ingest::ScheduleStatus.fallback_running?
  ensure
    Rails.cache.delete(Ingest::Scheduler::HEARTBEAT_KEY)
    scheduler&.stop!
  end

  test "once tuber is upgraded underneath it, it hands the schedule over and idles" do
    scheduler = firing_scheduler
    Rails.cache.write(Ingest::Scheduler::HEARTBEAT_KEY, Time.current)

    _result, syncs, _reports = against_tuber([]) { scheduler.tick }

    assert_equal :idle, scheduler.mode
    assert_equal 1, syncs, "the upgraded tuber came up empty; it needs the schedule"
    assert_empty scheduler.instance_variable_get(:@rufus).jobs, "tuber fires them now"
    refute Ingest::ScheduleStatus.fallback_running?, "the settings page must say tuber runs them"
  ensure
    Rails.cache.delete(Ingest::Scheduler::HEARTBEAT_KEY)
    scheduler&.stop!
  end

  test "an idle scheduler's tick touches nothing" do
    scheduler = Ingest::Scheduler.new
    scheduler.instance_variable_set(:@mode, :idle)
    asked = 0

    _result, syncs, _reports = against_tuber(-> { asked += 1 and [] }) { scheduler.tick }

    assert_equal 0, asked
    assert_equal 0, syncs
    refute Rails.cache.read(Ingest::Scheduler::HEARTBEAT_KEY), "tuber runs the schedule; this process mustn't claim to"
  ensure
    scheduler&.stop!
  end
end
