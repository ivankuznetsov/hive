require "open3"
require "time"
require "timeout"

require "hive"
require "hive/paths"
require "hive/pid_file"
require "hive/update_check/state"
require "hive/attempts/process_custody"
require "hive/attempts/process_identity"
require "hive/daemon/quiescence"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/process_registry"

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

      def initialize(hive_home: Hive::Paths.state_home, environment: ENV,
                     database: nil,
                     process_identity: Hive::Attempts::ProcessIdentity.new,
                     custody: Hive::Attempts::ProcessCustody.detect,
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     liveness_timeout_sec: 1.0)
        @hive_home = File.expand_path(hive_home)
        @pid_file = File.join(@hive_home, ".daemon.pid")
        @log_file = File.join(@hive_home, "logs", "daemon.log")
        @environment = environment
        @database = database || Hive::RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path(@hive_home)
        )
        @process_identity = process_identity
        @custody = custody
        @monotonic = monotonic
        @liveness_timeout_sec = Float(liveness_timeout_sec)
      end

      # Liveness plus producer-runtime evidence from the PID file.
      def running_state(max_pid_bytes: nil, require_start_time: false)
        running = false
        pid = nil
        uptime_sec = nil
        runtime = Hive::RuntimeIdentity.unknown
        runtime_observable = true
        if File.exist?(pid_file)
          payload = read_pid_file_payload(max_bytes: max_pid_bytes)
          pid = payload && payload["pid"]
          if pid.is_a?(Integer) && pid.positive?
            if pid_alive?(pid)
              ownership = pid_ownership(payload, pid)
              owned = if require_start_time
                ownership == :verified
              else
                pid_owned_by_us?(payload, pid)
              end
              # A live PID with legacy/unverified ownership may still be the
              # daemon. Do not let compact status substitute its caller's
              # runtime when the producer could not be attributed.
              runtime_observable = false unless owned || ownership == :reused
              if owned
                running = true
                uptime_sec = (Time.now - File.stat(pid_file).mtime).to_i
                runtime = Hive::RuntimeIdentity.parse(payload["runtime"]) || runtime
              end
            end
          else
            runtime_observable = false
          end
        end
        {
          running: running, pid: pid, uptime_sec: uptime_sec, runtime: runtime,
          runtime_observable: runtime_observable
        }
      rescue SystemCallError, IOError
        raise unless max_pid_bytes

        {
          running: false, pid: nil, uptime_sec: nil,
          runtime: Hive::RuntimeIdentity.unknown, runtime_observable: false
        }
      end

      def payload(state = running_state)
        running = state[:running]
        service_state = probe_service_state
        binary = binary_state(service_state)
        quiescence = quiescence_status
        {
          "schema" => "hive-daemon-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-status"),
          "ok" => true,
          "runtime" => state[:runtime] || Hive::RuntimeIdentity.unknown,
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
          "runtime_installation" => quiescence.fetch("runtime_installation"),
          "lifecycle" => quiescence.fetch("lifecycle"),
          "quiescence_capability" => quiescence.fetch("quiescence_capability"),
          # Agent-native parity with the TUI footer / bot push: expose the
          # update nudge so a programmatic caller can detect "behind" too.
          "current_version" => Hive::VERSION,
          "update_nudge" => update_nudge_payload
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

      def quiescence_status
        snapshot = @database.quiescence_status_snapshot
        diagnosis = snapshot.fetch(:diagnosis)
        installation = {
          "phase" => diagnosis.status == :missing ? "absent" : "active",
          "installation_id" => snapshot[:installation_id],
          "database_status" => diagnosis.status.to_s,
          "next_action" => diagnosis.error&.action ||
            (diagnosis.status == :missing ? "hive setup" : nil)
        }
        unless diagnosis.ok? && snapshot[:lifecycle]
          reason = diagnosis.status == :missing ? "runtime_absent" : "schema_#{diagnosis.status}"
          return {
            "runtime_installation" => installation,
            "lifecycle" => unknown_lifecycle(snapshot[:lifecycle], reason),
            "quiescence_capability" => unknown_capability(reason)
          }
        end

        lifecycle = build_lifecycle(snapshot.fetch(:lifecycle))
        capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
          database: @database, state_home: @hive_home,
          process_identity: @process_identity, custody: @custody
        ).call(
          snapshot: {
            reservations: snapshot.fetch(:reservations),
            processes: snapshot.fetch(:processes),
            attempts: snapshot.fetch(:attempts)
          }
        )
        proof = proof_verdict(lifecycle, installation_id: snapshot[:installation_id])
        liveness = liveness_verdict(snapshot, proof)
        phase = lifecycle.phase
        if lifecycle.phase == "paused" &&
           (!proof.fetch("valid") || !liveness.fetch("clear") || !capability.eligible?)
          phase = "quiescing"
        end

        {
          "runtime_installation" => installation,
          "lifecycle" => {
            "phase" => phase, "durable_phase" => lifecycle.phase,
            "generation" => lifecycle.generation, "revision" => lifecycle.revision,
            "mutation_sequence" => lifecycle.mutation_sequence,
            "admission_open" => lifecycle.admission_open?,
            "interrupted_attempt_ids" => lifecycle.interrupted_attempt_ids,
            "proof" => proof.reject { |key, _value| key == "payload" },
            "liveness" => liveness
          },
          "quiescence_capability" => capability.to_h
        }
      rescue Hive::RuntimeControlPlane::Error, Sequel::Error, SystemCallError, IOError => error
        reason = error.respond_to?(:code) ? error.code.to_s : "status_unavailable"
        {
          "runtime_installation" => {
            "phase" => "active", "installation_id" => nil,
            "database_status" => "unreadable", "next_action" =>
              (error.respond_to?(:action) ? error.action : nil)
          },
          "lifecycle" => unknown_lifecycle(nil, reason),
          "quiescence_capability" => unknown_capability(reason)
        }
      end

      def build_lifecycle(row)
        Hive::RuntimeControlPlane::Lifecycle.new(
          phase: row.fetch(:phase), generation: row.fetch(:generation),
          revision: row.fetch(:revision), mutation_sequence: row.fetch(:mutation_sequence),
          boot_id: row[:boot_id], deadline_monotonic: row[:deadline_monotonic],
          shutdown_grace_sec: row[:shutdown_grace_sec],
          interrupted_attempt_ids: Hive::RuntimeControlPlane::Codec.load_json(
            row.fetch(:interrupted_attempt_ids_json)
          ),
          quiesce_started_at: row[:quiesce_started_at], paused_at: row[:paused_at],
          resumed_at: row[:resumed_at], updated_at: row[:updated_at]
        )
      end

      def proof_verdict(lifecycle, installation_id:)
        return { "valid" => nil, "reason" => "not_applicable", "payload" => nil } unless
          lifecycle.phase == "paused"

        verdict = Hive::Daemon::FinalizationProof.new(state_home: @hive_home).verify(
          lifecycle: lifecycle, installation_id: installation_id
        )
        { "valid" => verdict.valid?, "reason" => verdict.reason, "payload" => verdict.payload }
      rescue StandardError => error
        { "valid" => false, "reason" => "proof_probe_failed:#{error.class}", "payload" => nil }
      end

      def liveness_verdict(snapshot, proof)
        return { "clear" => nil, "reason" => "not_applicable", "remaining" => [] } unless
          snapshot.dig(:lifecycle, :phase) == "paused"

        inventory = snapshot.fetch(:processes).map { |row| stringify(row) }
        inventory.concat(Array(proof.dig("payload", "inventory")))
        inventory.uniq! { |entry| [ entry["pid"], entry["start_fingerprint"], entry["service_identity"] ] }
        deadline = @monotonic.call + @liveness_timeout_sec
        remaining = inventory.filter_map do |entry|
          timeout = deadline - @monotonic.call
          if timeout <= 0
            entry.merge("last_known_state" => "unverifiable", "unknown_reason" => "probe_deadline")
          else
            status = Timeout.timeout(timeout) { @process_identity.status(entry) }
            next if %i[missing mismatched].include?(status)
            entry.merge(
              "last_known_state" => status.to_s,
              "unknown_reason" => (status == :matching ? "owned_process_alive" :
                "process_identity_unverifiable")
            )
          end
        rescue Timeout::Error
          entry.merge("last_known_state" => "unverifiable", "unknown_reason" => "probe_deadline")
        rescue StandardError => error
          entry.merge(
            "last_known_state" => "unverifiable",
            "unknown_reason" => "probe_failed:#{error.class}"
          )
        end
        {
          "clear" => remaining.empty?,
          "reason" => remaining.empty? ? nil : "owned_process_present_or_unverifiable",
          "remaining" => remaining
        }
      end

      def unknown_lifecycle(row, reason)
        durable_phase = row && row[:phase].to_s
        durable_phase = "unknown" unless %w[running quiescing paused resuming].include?(durable_phase)
        reported = durable_phase == "paused" ? "quiescing" : durable_phase
        {
          "phase" => reported, "durable_phase" => durable_phase,
          "generation" => integer_or_nil(row && row[:generation]),
          "revision" => integer_or_nil(row && row[:revision]),
          "mutation_sequence" => integer_or_nil(row && row[:mutation_sequence]),
          "admission_open" => durable_phase == "running" ? nil : false,
          "interrupted_attempt_ids" => [],
          "proof" => { "valid" => false, "reason" => reason },
          "liveness" => { "clear" => false, "reason" => reason, "remaining" => [] }
        }
      end

      def unknown_capability(reason)
        {
          "eligible" => false, "reason" => reason,
          "ownership_mode" => "unknown", "disqualifying_inventory" => []
        }
      end

      def integer_or_nil(value) = Integer(value, exception: false)

      def stringify(value)
        value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end

      # Read-only autostart-state snapshot for the envelope. A status probe
      # must never take down the running/pid reporting that precedes it, so
      # any failure degrades the service fields to null (the status schema
      # marks them required-but-nullable) instead of raising out of the
      # whole report.
      def probe_service_state
        require "hive/commands/daemon/service_installer"
        runtime_binary = @environment["HIVE_BIN"].to_s
        runtime_binary = nil if runtime_binary.empty?
        installer = Hive::Commands::Daemon::ServiceInstaller.new(binary_path: runtime_binary)
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
          elsif expected.to_s != "" && !same_binary?(installed, expected)
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

      def same_binary?(installed, expected)
        installed_path = File.expand_path(installed)
        expected_path = File.expand_path(expected)
        installed_path == expected_path || File.identical?(installed_path, expected_path)
      rescue SystemCallError
        false
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
        nudge = Hive::UpdateCheck::State.new(
          cleanup_orphans: false
        ).nudge
        return nil unless nudge

        { "latest" => nudge.latest, "channel" => nudge.channel, "command" => nudge.command }
      rescue StandardError
        nil
      end
    end
  end
end
