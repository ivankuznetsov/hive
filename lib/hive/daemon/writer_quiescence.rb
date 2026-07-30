require "hive/commands/daemon"
require "hive/daemon/operational_snapshot"
require "hive/daemon/status_report"
require "hive/invoked_binary"
require "hive/process_kill"

module Hive
  module Daemon
    # Captures the running daemon and its supervised process tree, requests the
    # daemon's normal graceful stop, verifies the generation-bound shutdown
    # acknowledgement, and refuses the caller's write boundary while any
    # captured process or process group remains live.
    class WriterQuiescence
      RESTART_TIMEOUT_SEC = 15
      SHUTDOWN_EVIDENCE_TIMEOUT_SEC = 15

      def initialize(
        operation:,
        hive_home: Hive::Paths.state_home,
        daemon_factory: nil,
        status_report: nil,
        tree_probe: Hive::ProcessKill.method(:process_tree_snapshot),
        process_alive: Hive::ProcessKill.method(:pid_alive?),
        captured_process_alive:
          Hive::ProcessKill.method(:captured_process_alive?),
        process_group_alive: nil,
        shutdown_evidence: nil,
        runtime_readiness: nil,
        binary_path: Hive::InvokedBinary.method(:path),
        command_runner: nil,
        clock: -> { Time.now },
        sleeper: ->(seconds) { sleep(seconds) },
        shutdown_evidence_timeout_sec: SHUTDOWN_EVIDENCE_TIMEOUT_SEC,
        restart_timeout_sec: RESTART_TIMEOUT_SEC
      )
        @operation = operation.to_s
        raise ArgumentError, "operation must be non-empty" if
          @operation.empty?

        @hive_home = hive_home
        @daemon_factory = daemon_factory || lambda do |subcommand|
          Hive::Commands::Daemon.new(subcommand, hive_home: @hive_home)
        end
        @status_report = status_report ||
          Hive::Daemon::StatusReport.new(hive_home: @hive_home)
        @tree_probe = tree_probe
        @process_alive = process_alive
        @captured_process_alive = captured_process_alive
        @process_group_alive =
          process_group_alive || method(:process_group_alive?)
        @shutdown_evidence = shutdown_evidence || lambda do |identity, now:|
          Hive::Daemon::OperationalSnapshot::Reader.new(
            path: Hive::Paths.operational_snapshot_path(@hive_home)
          ).shutdown_acknowledgement(
            expected_daemon: identity, now: now
          )
        end
        @runtime_readiness = runtime_readiness || lambda do |now:|
          Hive::Daemon::OperationalSnapshot::Reader.new(
            path: Hive::Paths.operational_snapshot_path(@hive_home),
            pid_path: File.join(@hive_home, ".daemon.pid")
          ).runtime_readiness(now: now)
        end
        @binary_path = binary_path
        @command_runner = command_runner || method(:run_command)
        @clock = clock
        @sleeper = sleeper
        @shutdown_evidence_timeout_sec =
          shutdown_evidence_timeout_sec
        @restart_timeout_sec = restart_timeout_sec
      end

      # True means this object stopped a verified daemon and the caller should
      # restart it after its protected write. False preserves an already
      # stopped profile.
      def quiesce!
        state = @status_report.running_state
        return false unless state[:running]

        pid = Integer(state.fetch(:pid))
        targets = @tree_probe.call(pid)
        unless targets &&
               targets.any? { |target| target.fetch(:pid) == pid }
          quiescence_failure!(
            "cannot capture the running daemon and supervised child tree",
            pid: pid
          )
        end

        daemon_target = targets.find { |target|
          target.fetch(:pid) == pid
        }
        start_time = daemon_target[:start_time].to_s
        if start_time.empty?
          quiescence_failure!(
            "cannot bind shutdown acknowledgement to the running daemon",
            pid: pid
          )
        end
        identity = Hive::Daemon::OperationalSnapshot.daemon_identity(
          pid: pid, process_start_time: start_time
        )

        @daemon_factory.call("stop").call
        acknowledgement = shutdown_acknowledgement!(identity)
        assert_stopped!(
          pid,
          merge_shutdown_inventory(
            targets, acknowledgement.fetch("child_inventory")
          )
        )
        true
      rescue Hive::ConcurrentRunError
        raise
      rescue KeyError, ArgumentError, TypeError, SystemCallError,
             IOError => error
        quiescence_failure!(
          "cannot verify daemon quiescence " \
          "(#{error.class}: #{error.message})"
        )
      end

      def restart!
        binary = @binary_path.call
        unless binary && File.file?(binary) && File.executable?(binary)
          raise Hive::UnavailableError,
                "#{@operation}: cannot restart daemon; " \
                "invoked Hive binary is unavailable"
        end

        result = @command_runner.call(
          [ binary, "daemon", "start", "--detach" ]
        )
        unless command_succeeded?(result)
          raise Hive::Error,
                "#{@operation}: daemon start command failed"
        end

        deadline = @clock.call + @restart_timeout_sec
        loop do
          state = @status_report.running_state
          if state[:running] &&
             @runtime_readiness.call(now: @clock.call)
            return true
          end
          break if @clock.call >= deadline

          @sleeper.call(0.05)
        end
        raise Hive::Error,
              "#{@operation}: daemon did not publish generation-bound " \
              "runtime readiness after restart"
      rescue Errno::ENOENT => error
        raise Hive::UnavailableError,
              "#{@operation}: cannot restart daemon (#{error.message})"
      end

      private

      def assert_stopped!(pid, targets)
        if @process_alive.call(pid)
          quiescence_failure!(
            "daemon PID remains live after stop", pid: pid
          )
        end

        children = targets.reject { |target|
          target.fetch(:pid) == pid
        }
        live_child = children.find { |target|
          @captured_process_alive.call(target)
        }
        if live_child
          quiescence_failure!(
            "supervised daemon child remains live after stop",
            pid: pid, child_pid: live_child.fetch(:pid)
          )
        end

        child_groups = children.filter_map do |target|
          pgid = target[:pgid]
          Integer(pgid) if pgid && Integer(pgid) > 1
        rescue ArgumentError, TypeError
          nil
        end.uniq
        live_group = child_groups.find { |pgid|
          @process_group_alive.call(pgid)
        }
        if live_group
          quiescence_failure!(
            "supervised daemon child process group remains live after stop",
            pid: pid, pgid: live_group
          )
        end
      end

      def shutdown_acknowledgement!(identity)
        deadline = @clock.call + @shutdown_evidence_timeout_sec
        loop do
          acknowledgement = @shutdown_evidence.call(
            identity, now: @clock.call
          )
          return acknowledgement if acknowledgement
          break if @clock.call >= deadline

          @sleeper.call(0.05)
        end

        raise Hive::ConcurrentRunError.new(
          "#{@operation}: daemon did not acknowledge admission closure " \
          "and child shutdown; daemon may now be stopped. Verify with " \
          "`hive daemon status --json`; if it reports stopped, recover " \
          "with `hive daemon start --detach`; refusing reset",
          holder: { pid: identity.fetch("pid") },
          lock_path: File.join(@hive_home, ".daemon.pid")
        )
      end

      def merge_shutdown_inventory(targets, inventory)
        final_targets = Array(inventory).map do |target|
          {
            pid: Integer(target.fetch("pid")),
            pgid: Integer(target.fetch("pgid")),
            start_time: target.fetch("start_time")
          }
        end
        (Array(targets) + final_targets).uniq do |target|
          [ target[:pid], target[:pgid], target[:start_time] ]
        end
      rescue KeyError, ArgumentError, TypeError
        quiescence_failure!(
          "daemon shutdown acknowledgement is malformed"
        )
      end

      def quiescence_failure!(message, **holder)
        raise Hive::ConcurrentRunError.new(
          "#{@operation}: #{message}; refusing reset",
          holder: holder,
          lock_path: File.join(@hive_home, ".daemon.pid")
        )
      end

      def process_group_alive?(pgid)
        Process.kill(0, -Integer(pgid))
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def run_command(argv)
        _pid, status = Process.wait2(Process.spawn(*argv))
        status
      end

      def command_succeeded?(result)
        return result.success? if result.respond_to?(:success?)

        result != false
      end
    end
  end
end
