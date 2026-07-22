require "digest"
require "json"
require "time"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/modules/decision_journal"
require "hive/modules/schedule_planner"
require "hive/modules/status"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    class Inspector
      def initialize(store:, attempt_store: nil, decision_journal: nil,
                     secret_availability: ->(name) { ENV.key?(name.to_s) },
                     planner: SchedulePlanner.new, clock: -> { Time.now.utc })
        @store = store
        @attempt_store = attempt_store || Hive::Attempts::Store.new(create_directories: false)
        @decision_journal = decision_journal || DecisionJournal.new(
          root: File.join(store.hive_state_path, "module-runtime"), create_directories: false
        )
        @secret_availability = secret_availability
        @planner = planner
        @clock = clock
      end

      def all(include_tombstones: false)
        @store.module_names.filter_map do |name|
          status = inspect(name, include_tombstone: include_tombstones)
          status if status && (include_tombstones || status["installed"])
        end.freeze
      end

      def inspect(name, include_tombstone: true)
        now = @clock.call.utc
        selection = @store.inspect_selection(name, include_tombstone: include_tombstone)
        return nil unless selection

        build_status(selection, now)
      rescue Hive::Error, JSON::ParserError, SystemCallError, IOError, KeyError, TypeError
        Status.corrupt(name: name, generated_at: now.iso8601(6))
      end

      private

      def build_status(selection, now)
        name = selection.fetch("name")
        generation = selection["active"] || selection["previous"]
        configuration = generation && @store.configuration(name, generation.fetch("configuration_digest"))
        hooks_state = @store.inspect_hooks(name)
        attempts = module_attempts(name)
        latest_attempt = attempts.max_by { |attempt| attempt["created_at"].to_s }
        decisions = @decision_journal.all.select { |decision| decision["module"] == name }
        latest_decision = decisions.max_by { |decision| decision.fetch("evaluated_at") }
        run = latest_run(name)
        activation = activation_evidence(name)
        artifacts = latest_attempt ? bounded_artifacts(latest_attempt) : []
        Status.new(
          "name" => name, "lifecycle_state" => lifecycle_state(selection, activation),
          "installed" => selection.fetch("installed"), "enabled" => selection.fetch("enabled"),
          "epoch" => selection.fetch("epoch"), "high_water_at" => selection.fetch("high_water_at"),
          "generated_at" => now.iso8601(6), "active" => selection["active"],
          "previous" => selection["previous"],
          "integrity" => integrity(name, generation, configuration, activation),
          "settings" => configuration ? setting_rows(configuration) : [],
          "grants" => configuration&.grants,
          "grant_digest" => configuration && digest(configuration.grants),
          "hooks" => configuration ? hook_rows(configuration, hooks_state, now) : [],
          "latest_decision" => decision_summary(latest_decision),
          "latest_attempt" => attempt_summary(latest_attempt),
          "retry" => retry_summary(run, latest_attempt), "artifacts" => artifacts,
          "failure_reason" => failure_reason(activation, latest_attempt),
          "history_available" => history_available?(name, decisions, attempts)
        )
      end

      def lifecycle_state(selection, activation)
        return "uninstalled_history" unless selection.fetch("installed")
        return "activating" if activation.fetch("fenced") || activation.fetch("journal")
        return "failed_activation" if activation.fetch("failure")
        return "disabled" unless selection.fetch("enabled")
        "active"
      end

      def integrity(name, generation, configuration, activation)
        {
          "configuration_valid" => !configuration.nil?,
          "generation_present" => generation && File.directory?(
            @store.generation_path(name, generation.fetch("source_commit"))
          ) ? true : false,
          "activation_fenced" => activation.fetch("fenced"),
          "journal_present" => activation.fetch("journal")
        }
      end

      def setting_rows(configuration)
        configuration.contract.fetch("settings").sort_by { |spec| spec.fetch("name") }.map do |spec|
          name = spec.fetch("name")
          secret = spec.fetch("type") == "secret" || spec["secret"] == true
          value = configuration.settings[name]
          {
            "name" => name, "type" => spec.fetch("type"),
            "required" => spec.fetch("required"), "secret" => secret,
            "value" => secret ? nil : value,
            "binding" => secret ? value : nil,
            "available" => secret && value ? @secret_availability.call(value) == true : nil
          }
        end
      end

      def hook_rows(configuration, hooks_state, now)
        configuration.contract.fetch("hooks").sort_by { |hook| hook.fetch("id") }.map do |hook|
          state = hooks_state.dig("hooks", hook.fetch("id")) || {}
          schedules = hook.fetch("schedules")
          next_at = schedules.filter_map { |schedule| @planner.next_after(schedule: schedule, now: now) }.min
          {
            "id" => hook.fetch("id"), "enabled" => state.fetch("enabled", false),
            "cursor" => state["cursor"], "binding_digest" => state["binding_digest"],
            "target" => hook.fetch("target"), "concurrency" => hook.fetch("concurrency"),
            "schedules" => schedules, "event_bindings" => hook.fetch("events"),
            "next_trigger_at" => next_at&.utc&.iso8601(6)
          }
        end
      end

      def module_attempts(name)
        @attempt_store.scan.records.select do |attempt|
          attempt.module_hook? && attempt.subject["module"] == name
        end
      end

      def decision_summary(decision)
        return nil unless decision
        decision.slice(
          "decision_id", "hook", "event_id", "event_name", "evaluated_at", "outcome",
          "reason", "binding_digest", "cursor_before", "cursor_after", "attempt_id"
        )
      end

      def attempt_summary(attempt)
        return nil unless attempt
        {
          "attempt_id" => attempt.attempt_id, "hook" => attempt.subject.fetch("hook"),
          "event_id" => attempt.subject.fetch("event_id"), "state" => attempt.state,
          "outcome" => attempt.outcome, "retry_charge" => attempt["retry_charge"],
          "created_at" => attempt["created_at"], "started_at" => attempt["started_at"],
          "ended_at" => attempt["ended_at"]
        }
      end

      def bounded_artifacts(attempt)
        Array(attempt["current_outputs"]).first(50).map do |reference|
          reference.slice("kind", "path", "sha256", "size_bytes", "media_type")
        end
      end

      def retry_summary(run, attempt)
        return run["retry"] if run.is_a?(Hash) && run["retry"].is_a?(Hash)
        return nil unless attempt && attempt["retry_charge"].positive?
        { "status" => attempt.final? ? "finished" : "pending", "charge" => attempt["retry_charge"] }
      end

      def failure_reason(activation, attempt)
        return "activation_failed" if activation.fetch("failure")
        return nil unless attempt
        return "attempt_lost" if attempt.state == "lost"
        return "hook_failed" if attempt.state == "terminal" && attempt.outcome != "succeeded"
        nil
      end

      def latest_run(name)
        paths = Dir.glob(File.join(@store.runtime_path(name), "runs", "*.json"))
        paths.filter_map do |path|
          data = JSON.parse(File.binread(path))
          data if data.is_a?(Hash)
        end.max_by { |run| [ run["updated_at"].to_s, run["created_at"].to_s ] }
      end

      def activation_evidence(name)
        module_root = File.dirname(@store.runtime_path(name))
        {
          "fenced" => File.file?(File.join(@store.runtime_path(name), "activation-barrier.json")),
          "journal" => File.file?(File.join(module_root, "activation.json")),
          "failure" => safe_failed_activation(name)
        }
      end

      def safe_failed_activation(name)
        bytes = File.binread(@store.failed_activation_path(name))
        data = JSON.parse(bytes)
        expected = %w[error_class failed_at reason schema_version]
        return nil unless data.keys.sort == expected && data["schema_version"] == 1 &&
                          data["reason"] == "activation_failed"
        data.slice("failed_at", "reason", "error_class")
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, SystemCallError, IOError
        { "reason" => "activation_failed" }
      end

      def history_available?(name, decisions, attempts)
        decisions.any? || attempts.any? || Dir.glob(File.join(@store.runtime_path(name), "runs", "*.json")).any?
      end

      def digest(value)
        ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(value))
      end
    end
  end
end
