require "hive"
require "hive/commands/daemon"
require "hive/daemon/operational_snapshot"
require "hive/daemon/status_report"
require "hive/install_channel"
require "hive/invoked_binary"
require "hive/process_kill"
require "shellwords"

module Hive
  module Commands
    class Update
      # A package replacement must not race an older daemon that still has the
      # released JobStore v2 format loaded. The daemon command already owns
      # graceful shutdown and its ChildSupervisor owns the child-tree / process
      # group drain. This wrapper captures the same external proof before the
      # stop, then refuses to invoke a package manager until every captured
      # writer is gone.
      class DaemonLifecycle
        RESTART_TIMEOUT_SEC = 15
        SHUTDOWN_EVIDENCE_TIMEOUT_SEC = 15

        def initialize(
          hive_home: Hive::Paths.state_home,
          daemon_factory: nil,
          status_report: nil,
          tree_probe: Hive::ProcessKill.method(:process_tree_snapshot),
          process_alive: Hive::ProcessKill.method(:pid_alive?),
          captured_process_alive: Hive::ProcessKill.method(:captured_process_alive?),
          process_group_alive: nil,
          shutdown_evidence: nil,
          binary_path: Hive::InvokedBinary.method(:path),
          command_runner: nil,
          clock: -> { Time.now },
          sleeper: ->(seconds) { sleep(seconds) },
          shutdown_evidence_timeout_sec: SHUTDOWN_EVIDENCE_TIMEOUT_SEC,
          restart_timeout_sec: RESTART_TIMEOUT_SEC
        )
          @hive_home = hive_home
          @daemon_factory = daemon_factory || lambda do |subcommand|
            Hive::Commands::Daemon.new(subcommand, hive_home: @hive_home)
          end
          @status_report = status_report ||
                           Hive::Daemon::StatusReport.new(hive_home: @hive_home)
          @tree_probe = tree_probe
          @process_alive = process_alive
          @captured_process_alive = captured_process_alive
          @process_group_alive = process_group_alive || method(:process_group_alive?)
          @shutdown_evidence = shutdown_evidence || lambda do |identity, now:|
            Hive::Daemon::OperationalSnapshot::Reader.new(
              path: Hive::Paths.operational_snapshot_path(@hive_home)
            ).shutdown_acknowledgement(expected_daemon: identity, now: now)
          end
          @binary_path = binary_path
          @command_runner = command_runner || method(:run_command)
          @clock = clock
          @sleeper = sleeper
          @shutdown_evidence_timeout_sec = shutdown_evidence_timeout_sec
          @restart_timeout_sec = restart_timeout_sec
        end

        # Returns true only when a verified running daemon was stopped and all
        # captured supervised writers are gone. Returns false for an already
        # stopped daemon, so callers leave it stopped after the package update.
        def quiesce!
          state = @status_report.running_state
          return false unless state[:running]

          pid = Integer(state.fetch(:pid))
          targets = @tree_probe.call(pid)
          unless targets && targets.any? { |target| target.fetch(:pid) == pid }
            raise_quiescence_failure!(
              "cannot capture the running daemon and supervised child tree",
              pid: pid
            )
          end

          daemon_target = targets.find { |target| target.fetch(:pid) == pid }
          start_time = daemon_target[:start_time].to_s
          if start_time.empty?
            raise_quiescence_failure!(
              "cannot bind shutdown acknowledgement to the running daemon", pid: pid
            )
          end
          identity = Hive::Daemon::OperationalSnapshot.daemon_identity(
            pid: pid, process_start_time: start_time
          )

          @daemon_factory.call("stop").call
          acknowledgement = shutdown_acknowledgement!(identity)
          assert_stopped!(
            pid,
            merge_shutdown_inventory(targets, acknowledgement.fetch("child_inventory"))
          )
          true
        rescue Hive::ConcurrentRunError
          raise
        rescue KeyError, ArgumentError, TypeError, SystemCallError, IOError => error
          raise_quiescence_failure!(
            "cannot verify daemon quiescence (#{error.class}: #{error.message})"
          )
        end

        # Starts the CLI again through the post-update stable wrapper, rather
        # than calling the current process's loaded Daemon class. The detached
        # child therefore loads the package generation just installed.
        def restart!
          binary = @binary_path.call
          unless binary && File.file?(binary) && File.executable?(binary)
            raise Hive::UnavailableError,
                  "hive update: cannot restart daemon; invoked Hive binary is unavailable"
          end

          result = @command_runner.call([ binary, "daemon", "start", "--detach" ])
          unless command_succeeded?(result)
            raise Hive::Error,
                  "hive update: candidate daemon start command failed"
          end

          deadline = @clock.call + @restart_timeout_sec
          loop do
            return true if @status_report.running_state[:running]
            break if @clock.call >= deadline

            @sleeper.call(0.05)
          end
          raise Hive::Error,
                "hive update: candidate daemon did not become running after restart"
        rescue Errno::ENOENT => error
          raise Hive::UnavailableError, "hive update: cannot restart daemon (#{error.message})"
        end

        private

        def assert_stopped!(pid, targets)
          if @process_alive.call(pid)
            raise_quiescence_failure!("daemon PID remains live after stop", pid: pid)
          end

          children = targets.reject { |target| target.fetch(:pid) == pid }
          live_child = children.find do |target|
            @captured_process_alive.call(target)
          end
          if live_child
            raise_quiescence_failure!(
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
          live_group = child_groups.find { |pgid| @process_group_alive.call(pgid) }
          if live_group
            raise_quiescence_failure!(
              "supervised daemon child process group remains live after stop",
              pid: pid, pgid: live_group
            )
          end
        end

        def shutdown_acknowledgement!(identity)
          deadline = @clock.call + @shutdown_evidence_timeout_sec
          loop do
            acknowledgement = @shutdown_evidence.call(identity, now: @clock.call)
            return acknowledgement if acknowledgement
            break if @clock.call >= deadline

            @sleeper.call(0.05)
          end

          raise Hive::ConcurrentRunError.new(
            "hive update: daemon did not acknowledge admission closure and child shutdown; " \
            "daemon may now be stopped. Verify with `hive daemon status --json`; " \
            "if it reports stopped, recover with `hive daemon start --detach`; " \
            "refusing package replacement",
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
          raise_quiescence_failure!("daemon shutdown acknowledgement is malformed")
        end

        def raise_quiescence_failure!(message, **holder)
          raise Hive::ConcurrentRunError.new(
            "hive update: #{message}; refusing package replacement",
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

      # Org+repo come from Hive::REPO_OWNER/REPO_NAME (one rename point). The
      # installer URL pins to the default branch so older bash-channel installs
      # fetch the newest installer rather than re-running their own vX.Y.Z
      # script forever. The script is downloaded to a tmpfile before execution;
      # no pipe-to-bash path is used here.
      BREW_TAP = "#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/hive".freeze
      INSTALL_URL = "https://raw.githubusercontent.com/#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/main/install.sh".freeze

      # Canonical one-line command shown to the user when they're behind,
      # per channel. Reuses BREW_TAP so a tap rename stays a one-diff change.
      # Returns nil for dev (git clone — `git pull` is the right move, but
      # there's no single canonical command to nudge). bash and aur both nudge
      # `hive update`: bash because auto-update (U7) isn't built yet, and aur
      # because the real updater picks yay OR paru at runtime — a hardcoded
      # `yay …` nudge would fail for paru-only users. `hive update` re-dispatches
      # to whichever helper the install actually has.
      def self.nudge_command(channel)
        case channel
        when "brew" then "brew upgrade #{BREW_TAP}"
        when "aur", "bash" then "hive update"
        end
      end

      def initialize(dry_run: false, output: $stdout, runner: nil, env: ENV,
                     channel: nil, daemon_lifecycle: nil,
                     candidate_binary_path: Hive::InvokedBinary.method(:path),
                     candidate_runner: nil,
                     effective_uid: -> { Process.euid })
        @dry_run = dry_run
        @output = output
        @runner = runner || method(:run_command)
        @env = env
        @channel = channel
        @daemon_lifecycle = daemon_lifecycle || DaemonLifecycle.new
        @candidate_binary_path = candidate_binary_path
        @candidate_runner = candidate_runner || method(:run_command)
        @effective_uid = effective_uid
      end

      def call
        channel = @channel || Hive::InstallChannel.detect
        prefix = @channel.nil? && channel == "bash" ? Hive::InstallChannel.detected_prefix : nil
        argv = command_for(channel, prefix: prefix)
        if argv.nil?
          @output.puts "channel: dev"
          @output.puts "suggested action: git pull && bundle install"
          return 0
        end

        if @dry_run
          @output.puts "channel: #{channel}"
          @output.puts "command: #{argv.join(' ')}"
          return 0
        end

        ensure_helper_available!(argv)
        daemon_was_running = @daemon_lifecycle.quiesce!
        begin
          invoke!(argv)
          invoke_candidate_migration!(channel: channel)
        ensure
          @daemon_lifecycle.restart! if daemon_was_running
        end
      end

      private

      def command_for(channel, prefix: nil)
        case channel
        when "brew" then [ "brew", "upgrade", BREW_TAP ]
        when "aur" then aur_command
        when "bash" then bash_installer_command(prefix: prefix)
        when "dev" then nil
        else
          raise Hive::ConfigError, "unknown hive install channel #{channel.inspect}"
        end
      end

      def bash_installer_command(prefix: nil)
        prefix_arg = prefix ? " --prefix=#{Shellwords.escape(prefix)}" : ""
        script = [
          "set -euo pipefail",
          'tmpdir="$(mktemp -d)"',
          'trap \'rm -rf "$tmpdir"\' EXIT',
          "curl -fsSL #{INSTALL_URL} -o \"$tmpdir/install.sh\"",
          "bash \"$tmpdir/install.sh\"#{prefix_arg}"
        ].join("; ")
        [ "bash", "-c", script ]
      end

      # Preflight the helper binary so a missing `brew` / `curl` /
      # `yay` produces an actionable error instead of a Ruby ENOENT
      # stacktrace from the process-replace call. The `bash` channel
      # invokes `curl` inside the shell command, so we check curl
      # rather than bash.
      def invoke!(argv)
        ensure_helper_available!(argv)

        result = @runner.call(argv)
        return if command_succeeded?(result)

        raise Hive::Error, "hive update: updater command failed"
      rescue Errno::ENOENT => e
        raise Hive::UnavailableError, "hive update: #{e.message}"
      end

      # The candidate sweep must be a fresh post-package process. Calling the
      # command class in this updater would retain the released process image
      # and could convert JobStore state with old code.
      def invoke_candidate_migration!(channel: nil)
        channel ||= @channel || Hive::InstallChannel.detect
        binary = @candidate_binary_path.call
        unless binary && File.file?(binary) && File.executable?(binary)
          raise Hive::UnavailableError,
                "hive update: cannot run candidate migration; invoked Hive binary is unavailable"
        end

        argv = [ binary, "refactor-patrol-migrate-installed" ]
        if @effective_uid.call.zero?
          argv << "--all-users"
          argv << "--ensure-retry-service" if channel == "bash"
        end
        result = @candidate_runner.call(argv)
        return if command_succeeded?(result)

        raise Hive::Error, "hive update: candidate migration command failed"
      rescue Errno::ENOENT => error
        raise Hive::UnavailableError,
              "hive update: cannot run candidate migration (#{error.message})"
      end

      def ensure_helper_available!(argv)
        helper = primary_helper(argv)
        return if helper_available?(helper)

        raise Hive::UnavailableError,
              "hive update: required helper '#{helper}' not found on PATH; install it and re-run"
      end

      def run_command(argv)
        _pid, status = Process.wait2(Process.spawn(*argv))
        status
      end

      def command_succeeded?(result)
        return result.success? if result.respond_to?(:success?)

        result != false
      end

      # Absolute paths come pre-resolved (e.g. from `aur_command`'s own
      # `which("yay")` lookup); skip the PATH probe for those and trust
      # the executable bit.
      def helper_available?(helper)
        return File.executable?(helper) if helper.start_with?("/")

        !which(helper).nil?
      end

      def primary_helper(argv)
        case argv.first
        when "bash" then "curl"
        else argv.first
        end
      end

      def aur_command
        helper = which("yay") || which("paru")
        unless helper
          raise Hive::UnavailableError,
                "hive update: install yay or paru, or re-run the bash installer from install.md"
        end

        [ helper, "-Syu", "hive-bin" ]
      end

      def which(name)
        Hive::InvokedBinary.which(name, env: @env)
      end
    end
  end
end
