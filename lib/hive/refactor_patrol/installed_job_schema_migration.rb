require "time"
require "hive/config"
require "hive/managed_directory"
require "hive/paths"
require "hive/refactor_patrol/registered_project_migration_status"

module Hive
  module RefactorPatrol
    # Product upgrade boundary for the JobStore generation change.
    #
    # Hive installations are user-scoped. Each installation sweeps the
    # complete registry visible to that user, including shared repositories
    # and custom state roots. Package hooks run this immediately for the
    # installing user; the CLI first-use gate repeats it for every other user
    # of a shared package when that user next invokes Hive.
    class InstalledJobSchemaMigration
      INTERNAL_ENV = "HIVE_JOB_SCHEMA_MIGRATION_INTERNAL".freeze
      ACTIVATION_LOCK = "refactor-patrol-job-v3.activation.lock".freeze
      RETRYABLE_STATUSES = %w[failed migration_required dry_run].freeze
      OBSERVATION_COMMANDS = %w[status watch doctor findings version].freeze
      EXEMPT_COMMANDS = %w[
        help uninstall refactor-patrol-migrate-installed
        refactor-patrol-schema-restore
      ].freeze
      EXEMPT_DAEMON_SUBCOMMANDS = %w[
        stop status reload tail queue
      ].freeze
      EXEMPT_WEB_SUBCOMMANDS = %w[status].freeze

      attr_reader :last_payload, :last_registry_digest, :last_ran,
                  :last_daemon_was_running, :last_daemon_restarted

      def self.eligible_argv?(argv, strict_no_write: false, env: ENV)
        args = Array(argv).map(&:to_s)
        return false if strict_no_write
        return false if env[INTERNAL_ENV] == "1"
        return false if env["HIVE_ATTEMPT_INTERNAL"] == "1"
        return false if args.empty?
        return false if args.any? { |arg| %w[--help -h].include?(arg) }

        command = top_level_command(args)
        return false if command.nil?
        return false if EXEMPT_COMMANDS.include?(command)
        return false if OBSERVATION_COMMANDS.include?(command)
        return false if command == "update" && boolean_option?(args, "dry-run")

        if command == "daemon"
          subcommand = subcommand_after(args, "daemon")
          return false if subcommand.nil?
          return false if EXEMPT_DAEMON_SUBCOMMANDS.include?(subcommand)
        end

        if command == "refactor-patrol"
          return false if boolean_option?(args, "list")
          return false if option_present?(args, "show")
        end
        if command == "web"
          subcommand = subcommand_after(args, "web")
          return false if EXEMPT_WEB_SUBCOMMANDS.include?(subcommand)
        end
        # Let Thor own missing-argument usage errors before any installation
        # activation. This preserves the command's human/JSON error contract
        # and avoids creating migration receipts for an invocation that could
        # never dispatch.
        return false if command == "connect" &&
                        subcommand_after(args, "connect").nil?

        true
      end

      def self.restart_daemon_after?(argv)
        args = Array(argv).map(&:to_s)
        top_level_command(args) != "daemon" ||
          subcommand_after(args, "daemon") != "start"
      end

      def self.top_level_command(args)
        Array(args).find do |arg|
          !arg.start_with?("-") && arg != "true" && arg != "false"
        end
      end
      private_class_method :top_level_command

      def self.subcommand_after(args, command)
        index = Array(args).index(command)
        return nil unless index

        Array(args).drop(index + 1).find { |arg| !arg.start_with?("-") }
      end
      private_class_method :subcommand_after

      def self.option_present?(args, name)
        Array(args).any? do |arg|
          arg == "--#{name}" || arg.start_with?("--#{name}=")
        end
      end
      private_class_method :option_present?

      def self.boolean_option?(args, name)
        value = nil
        Array(args).each do |arg|
          if %W[--no-#{name} --skip-#{name}].include?(arg)
            value = false
          elsif arg == "--#{name}"
            value = true
          elsif arg.start_with?("--#{name}=")
            raw = arg.split("=", 2).last.to_s.downcase
            value = !%w[false f no n 0].include?(raw)
          end
        end
        value == true
      end
      private_class_method :boolean_option?

      def initialize(
        registry: -> {
          Hive::Config.registered_project_entries(preserve_invalid: true)
        },
        identity_ensurer: Hive::Config.method(:ensure_project_identities!),
        status_store: RegisteredProjectMigrationStatus.new,
        coordinator_factory: nil,
        daemon_lifecycle: nil,
        activation_directory: nil,
        clock: -> { Time.now.utc }
      )
        @registry = registry
        @identity_ensurer = identity_ensurer
        @status_store = status_store
        @coordinator_factory = coordinator_factory || method(:build_coordinator)
        @daemon_lifecycle = daemon_lifecycle
        @activation_directory = activation_directory ||
          Hive::ManagedDirectory.new(
            root: File.join(Hive::Paths.state_home, "schema-migrations"),
            label: "installation JobStore schema migration"
          )
        @clock = clock
        reset_observation!
      end

      # Returns the persisted installation status. Individual project
      # failures are rows in that status and do not abort later projects.
      # Structural registry, lifecycle, or status failures remain fatal.
      def call(force: false, restart_daemon: true, now: nil)
        reset_observation!
        time = utc(now || @clock.call)

        # Validate HIVE_HOME and the registry before creating the activation
        # lock root; otherwise a typoed missing HIVE_HOME could be created and
        # accidentally made to look valid by this migration itself.
        @registry.call

        @activation_directory.with_lock(ACTIVATION_LOCK) do
          @identity_ensurer.call
          entries = Array(@registry.call).freeze
          digest = RegisteredProjectMigrationStatus.registry_digest(entries)
          current = readable_status
          @last_registry_digest = digest
          unless force || due?(current, digest: digest, now: time)
            @last_payload = current
            next current
          end

          daemon_was_running = daemon_lifecycle.quiesce!
          @last_daemon_was_running = daemon_was_running
          succeeded = false
          begin
            coordinator = @coordinator_factory.call(
              entries: entries, status_store: @status_store
            )
            coordinator.run(now: time, entries: entries)
            payload = coordinator.last_status_payload || @status_store.read
            unless payload
              raise Hive::ConfigError,
                    "installation migration did not persist status"
            end
            @last_payload = payload
            @last_ran = true
            succeeded = true
            payload
          ensure
            if daemon_was_running && (restart_daemon || !succeeded)
              daemon_lifecycle.restart!
              @last_daemon_restarted = true
            end
          end
        end
      end

      private

      def build_coordinator(entries:, status_store:)
        require "hive/refactor_patrol/registered_project_migration_coordinator"
        RegisteredProjectMigrationCoordinator.new(
          registry: -> { entries },
          status_store: status_store
        )
      end

      def daemon_lifecycle
        @daemon_lifecycle ||= DaemonLifecycle.new
      end

      def readable_status
        @status_store.read
      rescue Hive::ConfigError
        nil
      end

      def due?(payload, digest:, now:)
        return true unless payload.is_a?(Hash)
        return true unless payload["registry_digest"] == digest

        Array(payload["projects"]).any? do |project|
          next false unless project.is_a?(Hash)
          next false unless project["retryable"] == true
          next true if RETRYABLE_STATUSES.include?(project["status"]) &&
                       project["next_retry_at"].nil?

          retry_at = Time.iso8601(project["next_retry_at"].to_s).utc
          retry_at <= now
        rescue ArgumentError, TypeError
          true
        end
      end

      def utc(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "installation migration time is malformed"
      end

      def reset_observation!
        @last_payload = nil
        @last_registry_digest = nil
        @last_ran = false
        @last_daemon_was_running = false
        @last_daemon_restarted = false
      end

      # Candidate-side daemon fence that works against released daemons which
      # predate the new operational shutdown acknowledgement. It binds the
      # captured process tree to stable start times, invokes the candidate
      # stop command, and verifies every captured process and process group is
      # gone before any project conversion begins.
      class DaemonLifecycle
        RESTART_TIMEOUT_SEC = 15

        def initialize(
          hive_home: Hive::Paths.state_home,
          status_report: nil,
          daemon_factory: nil,
          tree_probe: nil,
          tree_confirmer: nil,
          captured_process_alive: nil,
          process_group_alive: nil,
          binary_path: nil,
          command_runner: nil,
          clock: -> { Time.now },
          sleeper: ->(seconds) { sleep(seconds) },
          restart_timeout_sec: RESTART_TIMEOUT_SEC
        )
          require "hive/daemon/status_report"
          require "hive/invoked_binary"
          require "hive/process_kill"
          @hive_home = hive_home
          @status_report = status_report ||
            Hive::Daemon::StatusReport.new(hive_home: hive_home)
          @daemon_factory = daemon_factory || lambda do |subcommand|
            require "hive/commands/daemon"
            Hive::Commands::Daemon.new(subcommand, hive_home: @hive_home)
          end
          @tree_probe = tree_probe ||
            Hive::ProcessKill.method(:process_tree_snapshot)
          @tree_confirmer = tree_confirmer ||
            Hive::ProcessKill.method(:confirm_process_tree_snapshot)
          @captured_process_alive = captured_process_alive ||
            Hive::ProcessKill.method(:captured_process_alive?)
          @process_group_alive = process_group_alive ||
            method(:default_process_group_alive?)
          @binary_path = binary_path || Hive::InvokedBinary.method(:path)
          @command_runner = command_runner || method(:run_command)
          @clock = clock
          @sleeper = sleeper
          @restart_timeout_sec = restart_timeout_sec
        end

        def quiesce!
          state = @status_report.running_state
          return false unless state[:running]

          pid = Integer(state.fetch(:pid))
          initial = @tree_probe.call(pid)
          targets = initial && @tree_confirmer.call(pid, initial)
          root = Array(targets).find { |target| target[:pid] == pid }
          unless root && Array(targets).all? do |target|
                   !target[:start_time].to_s.empty?
                 end
            quiescence_failure!(
              "cannot bind the released daemon process tree to stable identities",
              pid: pid
            )
          end

          @daemon_factory.call("stop").call
          assert_stopped!(pid, targets)
          true
        rescue Hive::ConcurrentRunError
          raise
        rescue KeyError, ArgumentError, TypeError, SystemCallError,
               IOError => error
          quiescence_failure!(
            "cannot verify released daemon quiescence " \
            "(#{error.class}: #{error.message})"
          )
        end

        def restart!
          binary = @binary_path.call
          unless binary && File.file?(binary) && File.executable?(binary)
            raise Hive::UnavailableError,
                  "cannot restart Hive daemon after JobStore migration; " \
                  "invoked Hive binary is unavailable"
          end

          result = @command_runner.call(
            [ binary, "daemon", "start", "--detach" ],
            { INTERNAL_ENV => "1" }
          )
          unless command_succeeded?(result)
            raise Hive::Error,
                  "candidate daemon start failed after JobStore migration"
          end

          deadline = @clock.call + @restart_timeout_sec
          loop do
            return true if @status_report.running_state[:running]
            break if @clock.call >= deadline

            @sleeper.call(0.05)
          end
          raise Hive::Error,
                "candidate daemon did not become running after JobStore migration"
        rescue Errno::ENOENT => error
          raise Hive::UnavailableError,
                "cannot restart Hive daemon after JobStore migration " \
                "(#{error.message})"
        end

        private

        def assert_stopped!(pid, targets)
          live = Array(targets).find do |target|
            @captured_process_alive.call(target)
          end
          if live
            quiescence_failure!(
              "captured daemon process remains live",
              pid: pid, child_pid: live[:pid]
            )
          end

          child_groups = Array(targets).filter_map do |target|
            next if target[:pid] == pid

            pgid = Integer(target[:pgid])
            pgid if pgid > 1
          rescue ArgumentError, TypeError
            nil
          end.uniq
          live_group = child_groups.find do |pgid|
            @process_group_alive.call(pgid)
          end
          if live_group
            quiescence_failure!(
              "captured daemon child process group remains live",
              pid: pid, pgid: live_group
            )
          end
        end

        def quiescence_failure!(message, **holder)
          raise Hive::ConcurrentRunError.new(
            "JobStore migration: #{message}; refusing conversion",
            holder: holder,
            lock_path: File.join(@hive_home, ".daemon.pid")
          )
        end

        def default_process_group_alive?(pgid)
          Process.kill(0, -Integer(pgid))
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end

        def run_command(argv, environment)
          _pid, status = Process.wait2(Process.spawn(environment, *argv))
          status
        end

        def command_succeeded?(result)
          return result.success? if result.respond_to?(:success?)

          result != false
        end
      end
    end
  end
end
