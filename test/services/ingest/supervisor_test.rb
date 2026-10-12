# frozen_string_literal: true

require "test_helper"

# Supervision, driven one tick at a time against a fake process table: no
# real forks, signals or clock here (see supervisor_fork_test.rb for those).
class Ingest::SupervisorTest < ActiveSupport::TestCase
  # What Process.wait2 hands back, minus what the supervisor doesn't read.
  Status = Struct.new(:exitstatus, :termsig) do
    def signaled? = !termsig.nil?
    def success? = exitstatus == 0
  end

  CRASHED = Status.new(1, nil)
  OOM_KILLED = Status.new(nil, Signal.list.fetch("KILL"))

  class FakeSupervisor < Ingest::Supervisor
    attr_accessor :clock
    attr_reader :forks, :signals, :exits, :events

    def initialize(roles)
      super(roles, builder: ->(_role) { [] })
      @clock = 1000.0
      @next_pid = 100
      @forks = []
      @signals = []
      @exits = []
      @events = []
    end

    def fork_child(role)
      @events << :fork
      (@next_pid += 1).tap { |pid| @forks << [role, pid] }
    end

    def reap = @exits.shift(@exits.size)

    def signal(sig, pid) = @signals << [sig, pid]

    def now = @clock

    def disconnect_all = @events << :disconnect

    def warmup = @events << :warmup

    def pid_of(role) = @forks.rfind { |r, _| r == role }&.last

    def die(role, status = CRASHED) = @exits << [pid_of(role), status]
  end

  def supervisor(roles = %w[ingest maintenance])
    FakeSupervisor.new(roles).tap(&:start)
  end

  def reports
    captured = []
    with_stub(Sentry, :capture_message, ->(message, **opts) { captured << [message, opts] }) { yield }
    captured
  end

  test "it forks one child per role, with no database connection open to inherit" do
    sup = supervisor

    assert_equal %w[ingest maintenance], sup.forks.map(&:first)
    assert_equal :disconnect, sup.events.first, "SQLite connections must not cross a fork"
    assert_equal [:warmup], sup.events.uniq & [:warmup]
    assert_operator sup.events.index(:warmup), :<, sup.events.index(:fork)
  end

  test "a child that dies is restarted, after a pause rather than at once" do
    sup = supervisor
    first = sup.pid_of("maintenance")
    sup.die("maintenance")

    sup.tick
    assert_equal first, sup.pid_of("maintenance"), "restarted with no pause: a crash loop would spin"

    sup.clock += 1
    sup.tick
    refute_equal first, sup.pid_of("maintenance")
    assert_equal 3, sup.forks.size, "only the dead role is restarted"
  end

  test "a child that keeps dying is restarted less and less often, up to a ceiling" do
    sup = supervisor
    waits = 7.times.map do
      sup.die("maintenance")
      sup.tick
      dead = sup.pid_of("maintenance")
      waited = 0
      while sup.pid_of("maintenance") == dead
        sup.clock += 1
        waited += 1
        sup.tick
      end
      waited
    end

    assert_equal [1, 2, 4, 8, 16, 30, 30], waits
  end

  test "a child that ran a good while before dying is restarted promptly again" do
    sup = supervisor
    3.times do
      sup.die("maintenance")
      sup.tick
      sup.clock += 10
      sup.tick
    end

    sup.clock += Ingest::Supervisor::STABLE_AFTER
    dead = sup.pid_of("maintenance")
    sup.die("maintenance")
    sup.tick
    sup.clock += 1
    sup.tick

    refute_equal dead, sup.pid_of("maintenance")
  end

  test "a child's death is reported, one issue per role" do
    sup = supervisor
    captured = reports do
      sup.die("ingest")
      sup.tick
    end

    assert_equal 1, captured.size
    message, opts = captured.first
    assert_match "ingest", message
    assert_equal ["worker", "child_died", "ingest"], opts[:fingerprint]
  end

  test "a child killed outright is named as most likely the out-of-memory killer" do
    sup = supervisor
    captured = reports do
      sup.die("maintenance", OOM_KILLED)
      sup.tick
    end

    assert_match(/SIGKILL.*out of memory/i, captured.first.first)
  end

  test "stopping asks every child to drain, once, and restarts nothing" do
    sup = supervisor
    sup.die("maintenance")
    sup.tick
    sup.stop!

    sup.tick
    sup.clock += 5
    sup.tick

    assert_equal [["TERM", sup.pid_of("ingest")]], sup.signals
    assert_equal 2, sup.forks.size, "the maintenance child waiting to restart must stay down"
    refute sup.finished?

    sup.die("ingest", Status.new(0, nil))
    sup.tick
    assert sup.finished?
  end

  test "a child still draining at the deadline is killed" do
    sup = supervisor
    sup.stop!
    sup.tick

    sup.clock += Ingest::Supervisor::SHUTDOWN_TIMEOUT - 1
    sup.tick
    assert_equal %w[TERM TERM], sup.signals.map(&:first)

    sup.clock += 2
    sup.tick
    assert_equal %w[TERM TERM KILL KILL], sup.signals.map(&:first)
  end

  test "a child stopping during shutdown is not reported as a death" do
    sup = supervisor
    sup.stop!
    sup.tick
    captured = reports do
      sup.die("ingest", Status.new(0, nil))
      sup.tick
    end

    assert_empty captured
  end
end
