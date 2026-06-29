require "open3"
require "stringio"
require "timeout"

require "hive/agent_profiles"
require "hive/claude_launcher"
require "hive/commands/doctor"
require "hive/config"
require "hive/daemon/recoverable_error_classifier"

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

      # `category` is the recoverable category symbol the classifier emits
      # (a member of RecoverableErrorClassifier::CATEGORIES) — NOT the
      # marker-reason string. The healer passes the classifier's symbol here.
      def probe(category)
        key = [ @tick_id, category.to_sym ]
        return @cache[key] if @cache.key?(key)

        @cache[key] = run_probe(category.to_sym)
      end

      private

      def run_probe(category)
        probes = []
        doctor = doctor_probe
        probes << doctor
        return result(category, probes) unless doctor[:ok]

        # Keep these branches in sync with RecoverableErrorClassifier::CATEGORIES.
        case category
        when :codex_auth
          probes.concat(codex_probes)
        when :claude_launcher
          probes.concat(claude_probes)
        else
          probes << probe_result(name: "unknown_reason", ok: false, stderr: "unknown health probe category #{category}")
        end

        result(category, probes)
      rescue StandardError => e
        result(category, [ probe_result(name: "health_probe_error", ok: false, stderr: "#{e.class}: #{e.message}") ])
      end

      def result(category, probes)
        {
          reason: category.to_s,
          ok: probes.all? { |probe| probe[:ok] },
          probes: probes
        }
      end

      def doctor_probe
        started = monotonic_ms
        doctor = @doctor_factory.call
        exit_code = doctor.call
        rows = doctor.rows
        failing = Array(rows).select { |row| FAILING_DOCTOR_STATUSES.include?(row[:status].to_s) }
        # Fail CLOSED on the universal precondition. `Hive::Commands::Doctor`
        # rescues a ConfigError/KeyError/ArgumentError to EXIT_CONFIG_ERROR
        # with `@rows` still nil, so `failing.empty?` would otherwise be true
        # (no rows to fail) and a broken doctor would silently pass the gate
        # guarding auto-clear. Require a clean exit AND a real row set, not
        # merely the absence of failing rows.
        healthy = exit_code == Hive::Commands::Doctor::EXIT_SUCCESS && !rows.nil? && failing.empty?
        message = if rows.nil?
          "doctor produced no rows (exit #{exit_code})"
        elsif !failing.empty?
          failing.map { |row| "#{row[:label] || row[:stage]}=#{row[:status]}" }.join(", ")
        elsif exit_code != Hive::Commands::Doctor::EXIT_SUCCESS
          "doctor exited #{exit_code}"
        else
          ""
        end
        probe_result(
          name: "doctor",
          ok: healthy,
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

      # Result-shape contract: only `:name` and `:ok` are guaranteed present.
      # `.compact` drops any nil value, so `:exit`/`:ms`/`:stdout_tail`/
      # `:stderr_tail` are absent-vs-nil ambiguous — a missing key means the
      # value was nil. Consumers iterating probes (beyond the audit log, which
      # persists the hash verbatim) must treat a missing key as nil.
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
