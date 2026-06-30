require "digest"
require "json"
require "stringio"
require "timeout"

require "hive"
require "hive/agent_profiles"
require "hive/commands/doctor"
require "hive/config"
require "hive/daemon/recoverable_error_classifier"

module Hive
  module Daemon
    # Computes dependency-health fingerprints and the retry signal gate.
    module HealthSignal
      FALLBACK_REPROBE_SEC = 3600
      DOCTOR_TIMEOUT_SEC = 15

      module_function

      # `category` is the recoverable category symbol the classifier emits
      # (a member of RecoverableErrorClassifier::CATEGORIES) — NOT the
      # marker-reason string. The healer passes the classifier's symbol here.
      def fingerprint(category:, config: Hive::Config::DEFAULTS, project_root: nil,
                      env: ENV, now: Time.now, doctor_rows: nil)
        parts = [
          "hive_version=#{Hive::VERSION}",
          "daemon_binary=#{File.expand_path($PROGRAM_NAME)}",
          "category=#{category}"
        ]

        # Keep these branches in sync with RecoverableErrorClassifier::CATEGORIES.
        case category.to_sym
        when :codex_auth
          parts.concat(codex_parts(config, env))
        when :claude_launcher
          parts.concat(claude_parts(config, project_root, doctor_rows))
        else
          parts << "unknown_reason"
        end

        ::Digest::SHA256.hexdigest(JSON.generate(parts))
      end

      def changed_or_fallback?(current_fingerprint:, last_fingerprint:, last_attempt_at:, now: Time.now,
                               fallback_sec: FALLBACK_REPROBE_SEC)
        return true if last_fingerprint.to_s.empty?
        return true if current_fingerprint != last_fingerprint
        return false unless last_attempt_at

        now - last_attempt_at >= fallback_sec
      end

      def codex_parts(config, env)
        codex_home = env["CODEX_HOME"].to_s.empty? ? File.expand_path("~/.codex") : env["CODEX_HOME"].to_s
        auth_path = File.join(codex_home, "auth.json")
        stat = stat_for(auth_path)
        [
          "CODEX_HOME=#{codex_home}",
          "codex_bin=#{profile_bin(:codex, config, "codex")}",
          "auth_json_present=#{!stat.nil?}",
          "auth_json_mtime=#{stat&.mtime&.to_f}"
        ]
      end

      def claude_parts(config, project_root, doctor_rows)
        wrapper = File.expand_path("../scripts/interactive_claude_wrapper.sh", __dir__)
        wrapper_stat = stat_for(wrapper)
        [
          "claude_bin=#{profile_bin(:claude, config, "claude")}",
          "claude_version=#{profile_version(:claude, config)}",
          "wrapper_mtime=#{wrapper_stat&.mtime&.to_f}",
          "doctor_rows=#{doctor_rows_digest(config, project_root, doctor_rows)}"
        ]
      end

      def profile_bin(name, config, fallback)
        Hive::AgentProfiles.lookup(name, cfg: config).bin
      rescue StandardError
        fallback
      end

      def profile_version(name, config)
        Hive::AgentProfiles.lookup(name, cfg: config).check_version!
      rescue StandardError => e
        # Fold a STABLE sentinel (the error class, never the message) into the
        # fingerprint. A transient PATH/exec error carries a varying message;
        # folding that raw string in would change the fingerprint on noise and
        # re-arm `changed_or_fallback?` without a genuine dependency-state
        # change. The success path still returns the real version string, so an
        # error→healthy transition flips the fingerprint as intended.
        "error:#{e.class}"
      end

      def doctor_rows_digest(config, project_root, rows)
        rows ||= begin
          output = StringIO.new
          doctor = Hive::Commands::Doctor.new(
            config: config,
            project_root: project_root,
            json: true,
            output: output
          )
          # Outer timeout on the in-process doctor: each sub-check carries its
          # own today, but a future check added without one would otherwise
          # stall the daemon tick that computes this fingerprint. A timeout
          # folds into the stable sentinel below (Timeout::Error is a
          # StandardError), keeping the digest stable rather than hanging.
          Timeout.timeout(DOCTOR_TIMEOUT_SEC) do
            doctor.call
            doctor.rows
          end
        rescue StandardError => e
          # Stable sentinel only (class, not message) — see profile_version.
          [ { error: "error:#{e.class}" } ]
        end

        normalized = Array(rows).map do |row|
          row.respond_to?(:to_h) ? row.to_h.transform_keys(&:to_s).sort.to_h : row.to_s
        end
        ::Digest::SHA256.hexdigest(JSON.generate(normalized.sort_by(&:to_s)))
      end

      def stat_for(path)
        File.stat(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
