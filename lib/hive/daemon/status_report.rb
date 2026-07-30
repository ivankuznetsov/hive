require "open3"
require "time"
require "timeout"

require "hive"
require "hive/paths"
require "hive/pid_file"
require "hive/refactor_patrol/registered_project_migration_status"
require "hive/update_check/state"

module Hive
  module Daemon
    # The `hive-daemon-status` envelope, built as a plain Hash so both
    # consumers share one producer: `hive daemon status --json` prints it,
    # and the web dashboard renders it in-process — no subprocess and no
    # $stdout capture (which under threaded Puma would race concurrent
    # requests' output).
    class StatusReport
      include Hive::PidFile

      # `binary_drift` states emitted in the envelope. Shared so the
      # JSON schema, the web `_daemon` view guard, and the docs table all
      # read the same source and can't drift apart. ACTIONABLE is the subset
      # that means "the installed unit points at the wrong/unreadable binary"
      # and should surface a repair affordance; "none"/"not_applicable" do not.
      BINARY_DRIFT_STATES = %w[none path version unparseable unreadable not_applicable].freeze
      BINARY_DRIFT_ACTIONABLE = %w[path version unparseable unreadable].freeze

      attr_reader :pid_file, :log_file

      def initialize(
        hive_home: Hive::Paths.state_home,
        migration_status:
          Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new(
            root: File.join(hive_home, "schema-migrations")
          )
      )
        @pid_file = File.join(hive_home, ".daemon.pid")
        @log_file = File.join(hive_home, "logs", "daemon.log")
        @migration_status = migration_status
      end

      # Liveness snapshot ({running:, pid:, uptime_sec:}) from the PID file.
      def running_state
        running = false
        pid = nil
        uptime_sec = nil
        if File.exist?(pid_file)
          payload = read_pid_file_payload
          pid = payload && payload["pid"]
          if pid && pid > 0 && pid_alive?(pid) && pid_owned_by_us?(payload, pid)
            running = true
            uptime_sec = (Time.now - File.stat(pid_file).mtime).to_i
          end
        end
        { running: running, pid: pid, uptime_sec: uptime_sec }
      end

      def payload(state = running_state)
        running = state[:running]
        service_state = probe_service_state
        binary = binary_state(service_state)
        {
          "schema" => "hive-daemon-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-status"),
          "ok" => true,
          "running" => running,
          "pid" => running ? state[:pid] : nil,
          "uptime_sec" => state[:uptime_sec],
          "pid_file" => pid_file,
          "log_file" => log_file,
          "service_installed" => service_state["service_installed"],
          "service_enabled" => service_state["service_enabled"],
          "unit_path" => service_state["unit_path"],
          "installed_binary" => binary.fetch("installed_binary"),
          "expected_binary" => binary.fetch("expected_binary"),
          "installed_binary_version" => binary.fetch("installed_binary_version"),
          "cli_version" => Hive::VERSION,
          "binary_drift" => binary.fetch("binary_drift"),
          # Agent-native parity with the TUI footer / bot push: expose the
          # update nudge so a programmatic caller can detect "behind" too.
          "current_version" => Hive::VERSION,
          "update_nudge" => update_nudge_payload,
          "schema_migrations" => schema_migration_payload
        }
      end

      # The web dashboard's contract: never raises. A not-running daemon is
      # an ordinary payload; only an unexpected probe failure degrades to a
      # minimal not-running hash.
      def safe_payload
        payload
      rescue StandardError => e
        { "ok" => false, "running" => false, "message" => e.message }
      end

      private

      # Read-only autostart-state snapshot for the envelope. A status probe
      # must never take down the running/pid reporting that precedes it, so
      # any failure degrades the service fields to null (the status schema
      # marks them required-but-nullable) instead of raising out of the
      # whole report.
      def probe_service_state
        require "hive/commands/daemon/service_installer"
        installer = Hive::Commands::Daemon::ServiceInstaller.new
        installer.service_state.merge(
          "installed_binary" => installer.installed_exec_binary,
          "expected_binary" => installer.expected_binary
        )
      rescue StandardError
        {
          "service_installed" => nil, "service_enabled" => nil, "unit_path" => nil,
          "installed_binary" => nil, "expected_binary" => nil
        }
      end

      def binary_state(service_state)
        installed = service_state["installed_binary"]
        expected = service_state["expected_binary"]
        installed_version = binary_version(installed)
        drift =
          if !service_state["service_installed"]
            # No autostart unit on disk (or the probe could not run): nothing
            # to compare against.
            "not_applicable"
          elsif installed.to_s.empty?
            # Unit present but its ExecStart/ProgramArguments binary could not
            # be parsed — distinct from "no service" so the operator gets a
            # signal that the installed unit is corrupt and needs repair.
            "unparseable"
          elsif expected.to_s != "" && File.expand_path(installed) != File.expand_path(expected)
            "path"
          elsif installed_version.nil?
            # Unit present and the binary is at the expected path, but
            # `--version` failed or timed out — the binary is wedged/unreadable.
            # Surface as actionable drift so a broken-but-correct-path binary
            # doesn't masquerade as healthy ("none") in status/the web repair.
            "unreadable"
          elsif installed_version != Hive::VERSION
            "version"
          else
            "none"
          end
        # The producer is the only writer of binary_drift; assert its output is
        # a member of the declared source of truth so the schema, the web view
        # guard, and the docs table can't silently drift from what is emitted.
        unless BINARY_DRIFT_STATES.include?(drift)
          raise "BUG: binary_drift #{drift.inspect} not in BINARY_DRIFT_STATES"
        end
        {
          "installed_binary" => installed,
          "expected_binary" => expected,
          "installed_binary_version" => installed_version,
          "binary_drift" => drift
        }
      end

      def binary_version(binary)
        return nil if binary.to_s.empty?

        # Bound the probe: a wedged installed binary must not hang
        # `daemon status --json` (and the web dashboard that renders this
        # report). A timeout or spawn failure returns nil, which the caller
        # treats as a version it could not read.
        out, _err, status = Timeout.timeout(10) { Open3.capture3(binary, "--version") }
        return nil unless status.success?

        out.strip[/\d+(?:\.\d+)+/] || out.strip
      rescue SystemCallError, Timeout::Error
        nil
      end

      # The daemon-written update nudge, as a plain Hash for the envelope
      # (nil when current or unknown). Never raises out of status.
      def update_nudge_payload
        nudge = Hive::UpdateCheck::State.new.nudge
        return nil unless nudge

        { "latest" => nudge.latest, "channel" => nudge.channel, "command" => nudge.command }
      rescue StandardError
        nil
      end

      def schema_migration_payload
        value = @migration_status.read
        return {
          "ok" => true,
          "schema" =>
            Hive::RefactorPatrol::RegisteredProjectMigrationStatus::SCHEMA,
          "schema_version" =>
            Hive::RefactorPatrol::RegisteredProjectMigrationStatus::SCHEMA_VERSION,
          "hive_version" => Hive::VERSION,
          "target_schema_version" => 3,
          "registry_digest" => nil,
          "updated_at" => nil,
          "daemon_restart_pending" => false,
          "user_profile" => migration_user_profile,
          "projects" => []
        } unless value

        { "ok" => true }.merge(value)
      rescue StandardError => error
        {
          "ok" => false,
          "schema" =>
            Hive::RefactorPatrol::RegisteredProjectMigrationStatus::SCHEMA,
          "schema_version" =>
            Hive::RefactorPatrol::RegisteredProjectMigrationStatus::SCHEMA_VERSION,
          "hive_version" => Hive::VERSION,
          "target_schema_version" => 3,
          "registry_digest" => nil,
          "updated_at" => nil,
          "daemon_restart_pending" => false,
          "user_profile" => migration_user_profile,
          "projects" => [],
          "error" => "#{error.class}: #{error.message}"
        }
      end

      def migration_user_profile
        return @migration_status.user_profile if
          @migration_status.respond_to?(:user_profile)

        Hive::RefactorPatrol::RegisteredProjectMigrationStatus
          .current_user_profile
      end
    end
  end
end
