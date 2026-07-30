require "time"
require "hive/config"
require "hive/managed_directory"
require "hive/paths"
require "hive/refactor_patrol/registered_project_migration_status"

module Hive
  module RefactorPatrol
    # One exact user profile's explicit JobStore generation upgrade boundary.
    # Package activation invokes this directly or through the privileged
    # all-user coordinator. Normal CLI startup and JobStore construction never
    # enter the converter.
    class InstalledJobSchemaMigration
      INTERNAL_ENV = "HIVE_JOB_SCHEMA_MIGRATION_INTERNAL".freeze
      ACTIVATION_LOCK = "refactor-patrol-job-v3.activation.lock".freeze
      RETRYABLE_STATUSES = %w[failed migration_required dry_run].freeze

      attr_reader :last_payload, :last_registry_digest, :last_ran,
                  :last_daemon_was_running, :last_daemon_restarted

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
            label: "user-profile JobStore schema migration"
          )
        @clock = clock
        reset_observation!
      end

      # Returns the persisted user-profile status. Individual project
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
          migration_due = force ||
            migration_due?(current, digest: digest, now: time)
          restart_pending =
            current.is_a?(Hash) &&
            current["daemon_restart_pending"] == true
          unless migration_due || restart_pending
            @last_payload = current
            next current
          end

          daemon_was_running = daemon_lifecycle.quiesce!
          @last_daemon_was_running = daemon_was_running
          restart_required = restart_pending || daemon_was_running
          succeeded = false
          begin
            payload = current
            if migration_due
              coordinator = @coordinator_factory.call(
                entries: entries, status_store: @status_store
              )
              coordinator.run(now: time, entries: entries)
              payload =
                coordinator.last_status_payload || @status_store.read
              unless payload
                raise Hive::ConfigError,
                      "user-profile migration did not persist status"
              end
              @last_ran = true
            end
            if restart_required
              payload = @status_store.write_daemon_restart_pending(
                payload,
                pending: true,
                now: time
              )
            end
            @last_payload = payload
            succeeded = true
            if restart_required && restart_daemon
              daemon_lifecycle.restart!(
                ready: method(:daemon_restart_acknowledged?)
              )
              @last_daemon_restarted = true
              payload = @status_store.read
              unless payload.is_a?(Hash) &&
                     payload["daemon_restart_pending"] == false
                raise Hive::ConfigError,
                      "candidate daemon did not acknowledge JobStore migration readiness"
              end
              @last_payload = payload
            end
            payload
          ensure
            if daemon_was_running && !succeeded
              daemon_lifecycle.restart!
              @last_daemon_restarted = true
            end
          end
        end
      end

      private

      def daemon_restart_acknowledged?
        payload = @status_store.read
        payload.is_a?(Hash) &&
          payload["daemon_restart_pending"] == false
      rescue Hive::ConfigError, SystemCallError, IOError
        false
      end

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

      def migration_due?(payload, digest:, now:)
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
              "user-profile migration time is malformed"
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

        def restart!(ready: nil)
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
            running = @status_report.running_state[:running]
            return true if running && (!ready || ready.call)
            break if @clock.call >= deadline

            @sleeper.call(0.05)
          end
          raise Hive::Error,
                "candidate daemon did not acknowledge readiness after JobStore migration"
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
          pid = Process.spawn(
            environment,
            *argv,
            in: File::NULL,
            out: File::NULL,
            err: File::NULL,
            close_others: true
          )
          _pid, status = Process.wait2(pid)
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
