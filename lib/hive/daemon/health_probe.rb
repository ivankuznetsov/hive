require "open3"
require "stringio"
require "timeout"

require "hive/agent_profiles"
require "hive/claude_launcher"
require "hive/commands/doctor"
require "hive/config"

module Hive
  module Daemon
    # Health probes for recoverable dependency-outage markers.
    #
    # The public result is intentionally hash-shaped so daemon audit events can
    # persist it directly without coupling to a value class.
    class HealthProbe
      DEFAULT_TIMEOUT_SEC = 15
      CODEX_SMOKE_TIMEOUT_SEC = 30
      TAIL_BYTES = 512
      FAILING_DOCTOR_STATUSES = %w[missing version_too_old].freeze

      def initialize(config:, project_root:, env: ENV, tick_id: nil,
                     doctor_factory: nil, capture3: nil, timeout_runner: nil)
        @config = config || Hive::Config::DEFAULTS
        @project_root = project_root
        @env = env
        @tick_id = tick_id
        @doctor_factory = doctor_factory || method(:default_doctor)
        @capture3 = capture3 || Open3.method(:capture3)
        @timeout_runner = timeout_runner || Timeout.method(:timeout)
        @cache = {}
      end

      def start_tick(tick_id)
        @tick_id = tick_id
        @cache.clear
      end

      def probe(reason)
        key = [ @tick_id, reason.to_sym ]
        return @cache[key] if @cache.key?(key)

        @cache[key] = run_probe(reason.to_sym)
      end

      private

      def run_probe(reason)
        probes = []
        doctor = doctor_probe
        probes << doctor
        return result(reason, probes) unless doctor[:ok]

        case reason
        when :codex_auth
          probes.concat(codex_probes)
        when :claude_launcher
          probes.concat(claude_probes)
        else
          probes << probe_result(name: "unknown_reason", ok: false, stderr: "unknown health probe reason #{reason}")
        end

        result(reason, probes)
      rescue StandardError => e
        result(reason, [ probe_result(name: "health_probe_error", ok: false, stderr: "#{e.class}: #{e.message}") ])
      end

      def result(reason, probes)
        {
          reason: reason.to_s,
          ok: probes.all? { |probe| probe[:ok] },
          probes: probes
        }
      end

      def doctor_probe
        started = monotonic_ms
        doctor = @doctor_factory.call
        exit_code = doctor.call
        rows = Array(doctor.rows)
        failing = rows.select { |row| FAILING_DOCTOR_STATUSES.include?(row[:status].to_s) }
        message = failing.map { |row| "#{row[:label] || row[:stage]}=#{row[:status]}" }.join(", ")
        probe_result(
          name: "doctor",
          ok: failing.empty?,
          exit: exit_code,
          stdout: message,
          ms: elapsed_ms(started)
        )
      rescue StandardError => e
        probe_result(name: "doctor", ok: false, stderr: "#{e.class}: #{e.message}", ms: elapsed_ms(started))
      end

      def default_doctor
        Hive::Commands::Doctor.new(
          config: @config,
          project_root: @project_root,
          json: true,
          output: StringIO.new
        )
      end

      def codex_probes
        login = shell_probe("codex_login_status", [ codex_bin, "login", "status" ])
        return [ login ] unless login[:ok]

        [
          login,
          shell_probe(
            "codex_exec_smoke",
            [ codex_bin, "exec", "--json", "Reply with OK." ],
            timeout_sec: CODEX_SMOKE_TIMEOUT_SEC
          )
        ]
      end

      def claude_probes
        wrapper = claude_wrapper_probe
        tmux = claude_tmux_probe
        version = claude_version_probe
        [ wrapper, tmux, version ]
      end

      def claude_wrapper_probe
        path = File.expand_path("../scripts/interactive_claude_wrapper.sh", __dir__)
        probe_result(name: "claude_wrapper", ok: File.file?(path), stdout: path)
      rescue SystemCallError => e
        probe_result(name: "claude_wrapper", ok: false, stderr: "#{e.class}: #{e.message}")
      end

      def claude_tmux_probe
        status, message = Hive::ClaudeLauncher.tmux_status
        probe_result(name: "claude_tmux", ok: status.to_s == "present", stdout: message.to_s)
      rescue StandardError => e
        probe_result(name: "claude_tmux", ok: false, stderr: "#{e.class}: #{e.message}")
      end

      def claude_version_probe
        started = monotonic_ms
        version = Hive::AgentProfiles.lookup(:claude, cfg: @config).check_version!
        probe_result(name: "claude_version", ok: true, stdout: version.to_s, ms: elapsed_ms(started))
      rescue StandardError => e
        probe_result(name: "claude_version", ok: false, stderr: "#{e.class}: #{e.message}", ms: elapsed_ms(started))
      end

      def shell_probe(name, cmd, timeout_sec: DEFAULT_TIMEOUT_SEC)
        started = monotonic_ms
        out, err, status = @timeout_runner.call(timeout_sec) do
          @capture3.call(@env.to_h, *cmd)
        end
        probe_result(
          name: name,
          ok: status.success?,
          exit: status.respond_to?(:exitstatus) ? status.exitstatus : nil,
          stdout: out,
          stderr: err,
          ms: elapsed_ms(started)
        )
      rescue Timeout::Error
        probe_result(name: name, ok: false, stderr: "timed out after #{timeout_sec}s", ms: elapsed_ms(started))
      rescue StandardError => e
        probe_result(name: name, ok: false, stderr: "#{e.class}: #{e.message}", ms: elapsed_ms(started))
      end

      def probe_result(name:, ok:, exit: nil, stdout: nil, stderr: nil, ms: nil)
        {
          name: name,
          ok: ok,
          exit: exit,
          stdout_tail: tail(stdout),
          stderr_tail: tail(stderr),
          ms: ms
        }.compact
      end

      def codex_bin
        Hive::AgentProfiles.lookup(:codex, cfg: @config).bin
      rescue StandardError
        "codex"
      end

      def tail(text)
        text = text.to_s
        return nil if text.empty?

        text.bytesize > TAIL_BYTES ? text.byteslice(-TAIL_BYTES, TAIL_BYTES).to_s.scrub : text
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end

      def elapsed_ms(started)
        return nil unless started

        monotonic_ms - started
      rescue StandardError
        nil
      end
    end
  end
end
