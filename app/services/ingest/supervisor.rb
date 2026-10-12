# frozen_string_literal: true

module Ingest
  # bin/worker with more than one role (`bin/worker all`): boots Rails once,
  # then forks a child per role, each running that role's consumers as
  # `bin/worker <role>` would.
  #
  # Processes rather than threads, because the sqlite3 gem holds the GVL for
  # the whole of a query: a maintenance job inside a long one (the dbstat walk,
  # a retention DELETE) stops every other thread in its process. That's why
  # ingest and maintenance were split in the first place (v1.7.5). Forked after
  # boot, the children share the memory Rails loaded until they write to it,
  # so this costs roughly one Rails boot less than two containers.
  #
  # This process does nothing but watch: a child that dies is restarted after
  # a pause that grows while it keeps dying; TERM or INT is passed on to every
  # child, which drains as it would on its own; and a child that outlives
  # SHUTDOWN_TIMEOUT is killed. It never touches a database or tuber, so a
  # child has nothing to inherit but the boot.
  class Supervisor
    # Restart pauses: 1s, doubling while the child keeps dying, up to the max.
    BACKOFF_START = 1
    BACKOFF_MAX = 30
    # A child that ran this long before dying starts the backoff afresh.
    STABLE_AFTER = 60
    # How long children get to drain once asked to stop. Under compose's
    # stop_grace_period for the worker service, so this process can still
    # kill stragglers and exit cleanly before Docker kills everything.
    SHUTDOWN_TIMEOUT = 25
    TICK = 0.5

    # Added to a role's oom_score_adj, so when the container's memory limit is
    # hit, the kernel kills that child rather than ingest. Maintenance is where
    # the big allocations are (dictionary training, the storage scan), and
    # what it loses is a run that its next fire repeats. Raised, never lowered:
    # lowering needs privileges a container doesn't have.
    OOM_SCORE_ADJ = {"maintenance" => 500}.freeze

    Child = Struct.new(:role, :pid, :started_at, :failures, :restart_at)

    def initialize(roles, builder: Worker.method(:consumers_for))
      @roles = roles
      @builder = builder
      @children = roles.to_h { |role| [role, Child.new(role, nil, nil, 0, nil)] }
      @stopping = false
      @shutdown_deadline = nil
    end

    def run
      trap("TERM") { stop! }
      trap("INT") { stop! }
      start
      until finished?
        tick
        sleep TICK
      end
      Rails.logger.info "[Supervisor] every child has stopped; exiting"
    end

    # Disconnects, then forks every role.
    def start
      @lifeline_r, @lifeline_w = IO.pipe
      disconnect_all
      warmup
      @children.each_value { |child| spawn(child) }
      Rails.logger.info "[Supervisor] running #{@children.keys.join(", ")} " \
        "(#{@children.values.map { |c| "#{c.role}=#{c.pid}" }.join(" ")})"
    end

    # What TERM and INT do. Safe from a trap: it only sets a flag.
    def stop!
      @stopping = true
    end

    def finished?
      @stopping && @children.each_value.none?(&:pid)
    end

    # One step: reap exits, then restart what's due — or, once stopping, pass
    # the stop on and enforce the deadline.
    def tick
      reap.each { |pid, status| exited(pid, status) }
      @stopping ? drain : restart_due
    end

    # --- What the tests replace ----------------------------------------------

    def fork_child(role)
      fork { child_main(role) }
    end

    def reap
      exits = []
      while (pid_status = Process.wait2(-1, Process::WNOHANG))
        exits << pid_status
      end
      exits
    rescue Errno::ECHILD
      exits
    end

    def signal(sig, pid)
      Process.kill(sig, pid)
    rescue Errno::ESRCH
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # SQLite connections must not cross a fork: two processes on one
    # connection corrupt the database, and the sqlite3 gem closes any a child
    # inherits, with a warning. The boot initializers leave some open.
    def disconnect_all
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
      Ingest::Tuber.reset_producer!
    end

    # Compacts the boot heap so more of it stays shared with the children.
    def warmup
      Process.warmup if Process.respond_to?(:warmup)
    end

    private

    def spawn(child)
      disconnect_all
      child.pid = fork_child(child.role)
      child.started_at = now
      child.restart_at = nil
    end

    def exited(pid, status)
      child = @children.each_value.find { |c| c.pid == pid } or return
      ran = now - child.started_at
      child.pid = nil
      return if @stopping

      child.failures = (ran >= STABLE_AFTER) ? 1 : child.failures + 1
      pause = [BACKOFF_START * 2**(child.failures - 1), BACKOFF_MAX].min
      child.restart_at = now + pause
      report_death(child, pid, status, ran, pause)
    end

    def restart_due
      @children.each_value do |child|
        next if child.pid || child.restart_at.nil? || now < child.restart_at
        spawn(child)
        Rails.logger.info "[Supervisor] restarted #{child.role} as #{child.pid}"
      end
    end

    def drain
      if @shutdown_deadline.nil?
        @shutdown_deadline = now + SHUTDOWN_TIMEOUT
        each_live_child { |child| signal("TERM", child.pid) }
      elsif now > @shutdown_deadline
        each_live_child do |child|
          Rails.logger.warn "[Supervisor] #{child.role} (#{child.pid}) still draining after #{SHUTDOWN_TIMEOUT}s; killing it"
          signal("KILL", child.pid)
        end
        @shutdown_deadline = Float::INFINITY
      end
    end

    def each_live_child(&) = @children.each_value.select(&:pid).each(&)

    def report_death(child, pid, status, ran, pause)
      how =
        if status.signaled?
          name = Signal.signame(status.termsig)
          (name == "KILL") ? "was killed (SIGKILL, most likely out of memory)" : "was killed (SIG#{name})"
        else
          "exited with status #{status.exitstatus}"
        end
      message = "Worker #{child.role} #{how} after #{ran.round}s; restarting it in #{pause}s"
      Rails.logger.error "[Supervisor] #{message}"
      Sentry.capture_message(message, level: :error, fingerprint: ["worker", "child_died", child.role],
        extra: {role: child.role, pid: pid, ran_seconds: ran.round, deaths_in_a_row: child.failures})
    rescue => e
      Rails.logger.error "[Supervisor] couldn't report #{child.role}'s death: #{e.class}: #{e.message}"
    end

    # The child: named for its role, its OOM score raised if it's the one to
    # sacrifice, watching the lifeline so it drains if this process dies.
    # Leaves with exit! so it never runs at_exit hooks inherited from here.
    def child_main(role)
      @lifeline_w.close
      Process.setproctitle("splat-worker #{role}")
      raise_oom_score(OOM_SCORE_ADJ[role])
      consumers = @builder.call(role)

      # Readable only at EOF: every write end is closed but this process's,
      # which goes when it dies — by SIGKILL too, which it can't trap.
      Thread.new do
        @lifeline_r.read
        warn "[Worker:#{role}] supervisor gone, draining and exiting"
        consumers.each(&:stop!)
      end

      Worker.run(role, consumers)
      flush_sentry
      exit!(0)
    rescue Exception => e # rubocop:disable Lint/RescueException
      Rails.logger.error "[Worker:#{role}] died: #{e.class}: #{e.message}"
      Sentry.capture_exception(e, extra: {role: role}) unless e.is_a?(SystemExit)
      flush_sentry
      exit!(1)
    end

    def raise_oom_score(adj)
      return unless adj
      path = "/proc/self/oom_score_adj"
      current = File.read(path).to_i
      File.write(path, adj.to_s) if adj > current
    rescue SystemCallError => e
      Rails.logger.warn "[Supervisor] couldn't set #{path}: #{e.class}: #{e.message}"
    end

    def flush_sentry
      Sentry.close if Sentry.initialized?
    rescue => e
      Rails.logger.warn "[Supervisor] couldn't flush Sentry: #{e.class}: #{e.message}"
    end
  end
end
