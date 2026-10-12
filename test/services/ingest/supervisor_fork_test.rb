# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The supervisor for real: forked, signalled and killed. It runs in a process
# of its own, forked from this one, with stand-in consumers that leave files
# behind to say what they did.
class Ingest::SupervisorForkTest < ActiveSupport::TestCase
  # Forking with the fixtures' transaction open would hand it to every child.
  self.use_transactional_tests = false

  # Says when it started and stopped, as files named for its role and pid.
  class FileConsumer
    def initialize(dir, role)
      @dir = dir
      @role = role
      @stop = false
    end

    def run
      File.write(File.join(@dir, "#{@role}.#{Process.pid}.started"), "")
      sleep 0.05 until @stop
      File.write(File.join(@dir, "#{@role}.#{Process.pid}.stopped"), "")
    end

    def stop! = @stop = true
  end

  setup do
    skip "needs fork and /proc" unless Process.respond_to?(:fork) && File.exist?("/proc/self/stat")
    @dir = Dir.mktmpdir("supervisor")
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
  end

  teardown do
    [@supervisor_pid, *started_pids].compact.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(@supervisor_pid) if @supervisor_pid
  rescue Errno::ECHILD
    nil
  ensure
    FileUtils.rm_rf(@dir) if @dir
  end

  # Forks the supervisor, which first opens a writable SQLite connection the
  # way the boot initializers (sqlite_auto_vacuum, logs_fts) do.
  def start_supervisor
    dir = @dir
    @supervisor_pid = fork do
      ApplicationRecord.connection.execute("PRAGMA user_version")
      Ingest::Supervisor.new(%w[ingest maintenance], builder: ->(role) { [FileConsumer.new(dir, role)] }).run
      exit!(0)
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "#{e.class}: #{e.message}"
      exit!(1)
    end
    wait_for("both children to start") { started_pids.size == 2 }
  end

  def marker_pids(kind) = Dir[File.join(@dir, "*.#{kind}")].map { |f| File.basename(f).split(".")[1].to_i }

  def started_pids = marker_pids("started")

  def started_pid(role) = Dir[File.join(@dir, "#{role}.*.started")].map { |f| File.basename(f).split(".")[1].to_i }.max

  def alive?(pid)
    Process.kill(0, pid)
    File.read("/proc/#{pid}/stat").rpartition(")").last.split.first != "Z"
  rescue Errno::ESRCH, Errno::ENOENT
    false
  end

  def wait_for(what, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def supervisor_exit_status
    status = nil
    wait_for("the supervisor to exit") { status = Process.wait2(@supervisor_pid, Process::WNOHANG)&.last }
    @supervisor_pid = nil
    status
  end

  test "TERM drains every child and the supervisor exits cleanly" do
    start_supervisor

    Process.kill("TERM", @supervisor_pid)

    assert supervisor_exit_status.success?
    assert_equal started_pids.sort, marker_pids("stopped").sort, "every child should finish its drain"
  end

  # Two processes on one SQLite connection can corrupt the database. Rails
  # closes what a child inherits, but the parent should have nothing open to
  # hand over: it has no use for a connection once Rails has booted.
  test "the supervisor holds no database open while its children run" do
    start_supervisor

    open_files = Dir["/proc/#{@supervisor_pid}/fd/*"].filter_map do |fd|
      File.readlink(fd)
    rescue Errno::ENOENT
      nil
    end
    assert_empty open_files.grep(/\.sqlite3(-wal|-shm)?\z/)
  end

  test "each child is named for its role, and maintenance goes first if memory runs out" do
    start_supervisor

    assert_equal "splat-worker ingest", File.read("/proc/#{started_pid("ingest")}/cmdline").delete("\0").strip
    assert_equal "splat-worker maintenance", File.read("/proc/#{started_pid("maintenance")}/cmdline").delete("\0").strip
    # Raised, never lowered: an unprivileged process can't go below what it
    # inherited.
    inherited = File.read("/proc/#{@supervisor_pid}/oom_score_adj").to_i
    assert_equal [inherited, Ingest::Supervisor::OOM_SCORE_ADJ.fetch("maintenance")].max,
      File.read("/proc/#{started_pid("maintenance")}/oom_score_adj").to_i
    assert_equal inherited, File.read("/proc/#{started_pid("ingest")}/oom_score_adj").to_i
  end

  test "a child killed outright is replaced" do
    start_supervisor
    dead = started_pid("maintenance")

    Process.kill("KILL", dead)

    wait_for("a new maintenance child") { started_pid("maintenance") != dead }
    assert alive?(started_pid("ingest")), "ingest carries on meanwhile"
  end

  test "children drain and exit if the supervisor itself is killed" do
    start_supervisor
    children = started_pids

    Process.kill("KILL", @supervisor_pid)
    Process.wait(@supervisor_pid)
    @supervisor_pid = nil

    wait_for("orphaned children to exit") { children.none? { |pid| alive?(pid) } }
    assert_equal children.sort, marker_pids("stopped").sort, "they should drain, not just vanish"
  end
end
