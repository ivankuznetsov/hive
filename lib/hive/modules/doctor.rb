require "json"
require "digest"
require "hive/module_package/validator"
require "hive/modules/hook_attempt"
require "hive/modules/inspector"
require "hive/modules/target_executor"
require "hive/modules/migration/patrols"
require "hive/workflow_package/canonical_json"

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

        checks = base_checks(status) + setting_checks(status) +
          module_integrity_checks(name, status) + runtime_checks(name) +
          migration_checks(name)
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
          check_row("activation_barrier", status.dig("integrity", "activation_fenced") ? "error" : "ok"),
          check_row("activation_journal", status.dig("integrity", "journal_present") ? "error" : "ok"),
          check_row(
            "activation_failure",
            status["lifecycle_state"] == "failed_activation" ? "error" : "ok"
          )
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
          Hive::Modules::HookAttempt.validate_execution_snapshot!(snapshot)
          check_row("execution_snapshot", "ok", subject: safe_subject(run["run_id"]))
        rescue Hive::ConfigError
          check_row("execution_snapshot", "error", subject: safe_subject(run && run["run_id"]))
        rescue JSON::ParserError, SystemCallError, IOError
          check_row("execution_snapshot", "error", subject: File.basename(path, ".json"))
        end
      end

      def migration_checks(name)
        return [] unless Hive::Modules::Migration::Patrols::MODULES.include?(name.to_s)

        diagnostic = Hive::Modules::Migration::Patrols.diagnostic(
          File.dirname(@store.hive_state_path), name,
          hive_state_path: @store.hive_state_path
        )
        healthy = diagnostic.fetch("status") != "corrupt" && diagnostic.fetch("admission")
        [ check_row("migration_ownership", healthy ? "ok" : "error",
                    subject: diagnostic["blocker"] || diagnostic.fetch("status")) ]
      end

      def module_integrity_checks(name, status)
        generation = status["active"] || status["previous"]
        return [] unless generation
        return [] if generation["origin"] == "legacy_workflow"

        configuration = @store.configuration(name, generation.fetch("configuration_digest"))
        path = @store.generation_path(name, generation.fetch("source_commit"))
        manifest_valid = begin
          validation = Hive::ModulePackage::Validator.validate!(
            path, expected_name: name,
            expected_manifest_digest: generation.fetch("manifest_digest"),
            catalog_commit: generation.fetch("catalog_commit")
          )
          validation.manifest.digest == generation.fetch("manifest_digest")
        rescue Hive::Error, SystemCallError, IOError
          false
        end
        targets_valid = begin
          Hive::Modules::TargetExecutor.new.validate_generation!(path, configuration)
          true
        rescue Hive::Error, SystemCallError, IOError
          false
        end
        hooks_valid = hooks_valid?(name, configuration)
        setup_valid = begin
          @store.inspect_setup_outbox(name)
          true
        rescue Hive::Error, SystemCallError, IOError
          false
        end
        [
          check_row("manifest_inventory", manifest_valid ? "ok" : "error"),
          check_row("target_bindings", targets_valid ? "ok" : "error"),
          check_row("hook_bindings", hooks_valid ? "ok" : "error"),
          check_row("setup_outbox", setup_valid ? "ok" : "error")
        ]
      rescue Hive::Error, KeyError, SystemCallError, IOError
        [
          check_row("manifest_inventory", "error"),
          check_row("target_bindings", "error"),
          check_row("hook_bindings", "error"),
          check_row("setup_outbox", "error")
        ]
      end

      def hooks_valid?(name, configuration)
        state = @store.inspect_hooks(name)
        return false unless state.fetch("configuration_digest") == configuration.digest

        expected = configuration.contract.fetch("hooks").to_h do |hook|
          [ hook.fetch("id"), ::Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(hook)
          ) ]
        end
        rows = state.fetch("hooks")
        rows.keys.sort == expected.keys.sort && rows.all? do |id, row|
          row.is_a?(Hash) && row.keys.sort == %w[binding_digest cursor enabled] &&
            [ true, false ].include?(row["enabled"]) &&
            (row["cursor"].nil? || row["cursor"].is_a?(String)) &&
            row["binding_digest"] == expected.fetch(id)
        end
      rescue KeyError, TypeError
        false
      end

      def safe_subject(value)
        text = value.to_s
        return nil if text.empty?

        text.byteslice(0, 128)
      end

      def check_row(code, status, subject: nil)
        { "code" => code, "status" => status, "subject" => subject }
      end
    end
  end
end
