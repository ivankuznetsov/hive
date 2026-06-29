require "digest"
require "json"
require "stringio"

require "hive"
require "hive/agent_profiles"
require "hive/commands/doctor"
require "hive/config"

module Hive
  module Daemon
    # Computes dependency-health fingerprints and the retry signal gate.
    module HealthSignal
      FALLBACK_REPROBE_SEC = 3600

      module_function

      def fingerprint(reason:, config: Hive::Config::DEFAULTS, project_root: nil,
                      env: ENV, now: Time.now, doctor_rows: nil)
        parts = [
          "hive_version=#{Hive::VERSION}",
          "daemon_binary=#{File.expand_path($PROGRAM_NAME)}",
          "reason=#{reason}"
        ]

        case reason.to_sym
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
        "#{e.class}: #{e.message}"
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
          doctor.call
          doctor.rows
        rescue StandardError => e
          [ { error: "#{e.class}: #{e.message}" } ]
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
