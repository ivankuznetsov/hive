require "json"
require "hive/modules/inspector"

module Hive
  module Modules
    class Doctor
      def initialize(inspector:, store:)
        @inspector = inspector
        @store = store
      end

      def check(name)
        status = @inspector.inspect(name, include_tombstone: true)
        raise Hive::ConfigError, "module #{name.inspect} is not installed and has no history" unless status

        checks = base_checks(status) + setting_checks(status) + runtime_checks(name)
        {
          "status" => status.to_h, "healthy" => checks.none? { |row| row.fetch("status") == "error" },
          "checks" => checks
        }
      end

      private

      def base_checks(status)
        [
          check_row("selection", status["lifecycle_state"] == "corrupt" ? "error" : "ok"),
          check_row("configuration_digest", status.dig("integrity", "configuration_valid") ? "ok" : "error"),
          check_row("generation_payload", status.dig("integrity", "generation_present") ? "ok" : "error"),
          check_row("activation_barrier", status.dig("integrity", "activation_fenced") ? "warning" : "ok"),
          check_row("activation_journal", status.dig("integrity", "journal_present") ? "warning" : "ok")
        ]
      end

      def setting_checks(status)
        status.fetch("settings").select { |row| row.fetch("secret") }.map do |row|
          state = row.fetch("required") && row["available"] != true ? "error" : "ok"
          check_row("secret_binding", state, subject: row.fetch("name"))
        end
      end

      def runtime_checks(name)
        paths = Dir.glob(File.join(@store.runtime_path(name), "runs", "*.json"))
        paths.filter_map do |path|
          run = JSON.parse(File.binread(path))
          next if %w[succeeded failed cancelled].include?(run["status"])
          snapshot = run["execution_snapshot"]
          complete = snapshot.is_a?(Hash) && %w[descriptor configuration grants].all? do |key|
            snapshot[key].is_a?(Hash) && !snapshot[key].empty?
          end
          check_row("execution_snapshot", complete ? "ok" : "error", subject: run["run_id"])
        rescue JSON::ParserError, SystemCallError, IOError
          check_row("execution_snapshot", "error", subject: File.basename(path, ".json"))
        end
      end

      def check_row(code, status, subject: nil)
        { "code" => code, "status" => status, "subject" => subject }
      end
    end
  end
end
