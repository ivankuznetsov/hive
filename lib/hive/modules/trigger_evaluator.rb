require "digest"
require "time"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    TriggerEvaluation = Data.define(
      :outcome, :reason, :binding_digest, :cursor_before, :cursor_after
    ) do
      def launch? = outcome == "launch"
    end

    # Pure trigger decision core shared by production dispatch and dry-run.
    # Capacity and live-concurrency facts are supplied snapshots so evaluation
    # itself never acquires a lock or mutates a cursor.
    class TriggerEvaluator
      def evaluate(selection:, configuration:, hook:, hook_state:, event:,
                   activation_fenced: false, duplicate: false,
                   capacity_blocked: false, concurrency_blocked: false,
                   secret_availability: {})
        binding_digest = digest(hook)
        cursor = hook_state && hook_state["cursor"]
        after = event.fetch("event_id")
        return result("skip", "not_installed", binding_digest, cursor, cursor) unless selection
        unless selection.fetch("installed")
          return result("skip", "uninstalled", binding_digest, cursor, cursor)
        end
        return result("skip", "disabled", binding_digest, cursor, cursor) unless selection.fetch("enabled")
        return result("skip", "activation_fenced", binding_digest, cursor, cursor) if activation_fenced
        enabled = configuration.hooks.fetch(hook.fetch("id")) && hook_state&.fetch("enabled", false)
        return result("skip", "hook_disabled", binding_digest, cursor, after) unless enabled
        return result("skip", "no_match", binding_digest, cursor, after) unless binding_matches?(hook, event)
        return result("skip", "duplicate", binding_digest, cursor, after) if duplicate
        if stale?(selection, event) || cursor == after
          return result("skip", "cursor_stale", binding_digest, cursor, after)
        end
        unless required_secrets_available?(configuration, secret_availability)
          return result("skip", "permission_blocked", binding_digest, cursor, after)
        end
        return result("skip", "concurrency_blocked", binding_digest, cursor, after) if concurrency_blocked
        return result("skip", "capacity_blocked", binding_digest, cursor, after) if capacity_blocked

        result("launch", "admitted", binding_digest, cursor, after)
      rescue KeyError, TypeError
        result("skip", "invalid_binding", digest(hook || {}), hook_state&.[]("cursor"), nil)
      end

      private

      def binding_matches?(hook, event)
        case event.fetch("event_name")
        when "schedule"
          binding = event.dig("payload", "schedule")
          binding.is_a?(String) && hook.fetch("schedules").include?(binding)
        else
          hook.fetch("events").include?(event.fetch("event_name"))
        end
      end

      def stale?(selection, event)
        high_water = selection["high_water_at"]
        occurred_at = event.fetch("occurred_at")
        occurred_at = Time.iso8601(occurred_at) unless occurred_at.is_a?(Time)
        high_water && occurred_at < Time.iso8601(high_water)
      rescue ArgumentError, TypeError
        true
      end

      def required_secrets_available?(configuration, availability)
        specs = configuration.contract.fetch("settings")
        specs.select { |setting| setting.fetch("type") == "secret" && setting.fetch("required") }.all? do |setting|
          binding = configuration.settings.fetch(setting.fetch("name"))
          availability.fetch(binding, false) == true
        end
      end

      def result(outcome, reason, binding_digest, before, after)
        TriggerEvaluation.new(
          outcome: outcome, reason: reason, binding_digest: binding_digest,
          cursor_before: before, cursor_after: after
        )
      end

      def digest(value)
        ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(value))
      end
    end
  end
end
