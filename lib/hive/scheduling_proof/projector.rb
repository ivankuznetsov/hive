require "time"
require "hive/diagnostic_helpers"
require "hive/secret_patterns"
require "hive/scheduling_proof/action_projector"
require "hive/scheduling_proof/freshness"
require "hive/scheduling_proof/reason"
require "hive/workflows"

module Hive
  module SchedulingProof
    class Projector
      attr_reader :as_of

      def initialize(as_of:, daemon_running:, heartbeat_at:, poll_interval_sec:,
                     unavailable_live_claims: [])
        @as_of = coerce_time(as_of)
        @daemon_running = daemon_running == true
        @heartbeat_at = heartbeat_at
        @poll_interval_sec = poll_interval_sec
        @unavailable_live_claims = unavailable_live_claims
      end

      def project_task(row:, enrolled:, attempt: nil, observation: nil)
        source = stringify(row)
        return nil unless enrolled
        return nil if archived?(source)

        generation = task_generation(source)
        live_attempt = compatible_attempt(attempt, source, generation)
        current_observation = compatible_observation(observation, source, generation)
        freshness = Freshness.project(
          as_of: as_of, heartbeat_at: @heartbeat_at,
          poll_interval_sec: @poll_interval_sec,
          daemon_running: @daemon_running,
          unavailable_live_claims: @unavailable_live_claims
        )
        prior_reason = current_observation && Reason.normalize(current_observation["reason"])
        kind = live_attempt ? "execution" : "idle"
        reason = primary_reason(kind, prior_reason, freshness)
        attempt_id = live_attempt && live_attempt["attempt_id"]
        action = ActionProjector.project(
          reason: reason,
          action_key: source["action"],
          command: source["suggested_command"],
          stage: source["stage"],
          task_generation: generation,
          attempt_id: attempt_id,
          authoritative_action: current_observation && current_observation["action"]
        )

        canonical(
          "kind" => kind,
          "summary" => bounded(Reason.summary(reason)),
          "reason" => reason,
          "identity" => identity(source, generation),
          "source" => source_identity(current_observation, generation, attempt_id),
          "enrolled" => true,
          "eligible" => kind == "idle" && current_observation&.fetch("eligible", false) == true,
          "queue" => queue_evidence(current_observation, freshness),
          "capacity" => capacity_evidence(current_observation, live_attempt),
          "attempt" => attempt_evidence(live_attempt),
          "provider" => evidence_hash(current_observation, "provider"),
          "dependency" => dependency_evidence(source, current_observation),
          "babysitter" => evidence_hash(current_observation, "babysitter"),
          "retry" => retry_evidence(live_attempt, current_observation),
          "last_transition_at" => current_observation&.fetch("last_transition_at", nil),
          "last_dispatch" => evidence_hash(current_observation, "last_dispatch"),
          "error" => error_evidence(source, current_observation),
          "freshness" => freshness,
          "prior" => prior_evidence(reason, prior_reason, current_observation),
          "action" => action
        )
      end

      private

      def archived?(row)
        Hive::Workflows.all_terminal_stage_dirs.include?(row["stage"]) || row["action"] == "archived"
      end

      def task_generation(row)
        value = row["condition_task_generation"]
        value.is_a?(Integer) && value >= 0 ? value : 0
      end

      def primary_reason(kind, prior_reason, freshness)
        return "executing" if kind == "execution"
        return "daemon_not_running" if freshness["daemon_state"] == "stopped"
        return "daemon_stale" if freshness["daemon_state"] == "stale"

        prior_reason || "live_evidence_unavailable"
      end

      def compatible_attempt(candidate, row, generation)
        value = stringify(candidate)
        return nil if value.empty?
        return nil unless %w[launching running].include?(value["state"])
        return nil unless value["project"] == row["project"]
        return nil unless value["task_slug"] == row["slug"]
        return nil unless value["intended_stage"] == row["stage"]
        return nil unless value["task_input_epoch"] == generation

        value
      end

      def compatible_observation(candidate, row, generation)
        value = stringify(candidate)
        return nil if value.empty?
        return nil unless value["project"] == row["project"]
        return nil unless value["task_slug"] == row["slug"]
        return nil unless value["stage"] == row["stage"]
        return nil unless value["task_generation"] == generation

        value
      end

      def identity(row, generation)
        {
          "project" => row["project"],
          "project_path" => row["project_path"],
          "task_id" => row["id"],
          "task_slug" => row["slug"],
          "workflow" => row["workflow"],
          "stage" => row["stage"],
          "task_generation" => generation
        }
      end

      def source_identity(observation, generation, attempt_id)
        {
          "task_generation" => observation&.fetch("task_generation", generation) || generation,
          "attempt_id" => observation&.fetch("attempt_id", attempt_id) || attempt_id,
          "observed_at" => observation&.fetch("observed_at", nil)
        }
      end

      def queue_evidence(observation, freshness)
        position = freshness["stale"] ? nil : observation&.fetch("queue_position", nil)
        { "position" => position }
      end

      def capacity_evidence(observation, attempt)
        evidence = evidence_hash(observation, "capacity") || {}
        evidence.merge("owns_slot" => !attempt.nil?)
      end

      def attempt_evidence(attempt)
        return nil unless attempt

        {
          "id" => attempt["attempt_id"],
          "state" => attempt["state"],
          "provider" => attempt["provider"],
          "heartbeat_at" => attempt["heartbeat_at"]
        }
      end

      def retry_evidence(attempt, observation)
        supplied = evidence_hash(observation, "retry")
        return supplied if supplied
        return nil unless attempt

        { "charge" => attempt["retry_charge"], "retry_after" => nil, "next_probe_at" => nil }
      end

      def dependency_evidence(row, observation)
        supplied = evidence_hash(observation, "dependency")
        return supplied if supplied
        return nil unless row["blocked"] || row["admission_error"]

        {
          "blocked_by" => row["blocked_by"],
          "dependency_stage" => row["dependency_stage"],
          "admission_error" => row["admission_error"]
        }
      end

      def error_evidence(row, observation)
        supplied = evidence_hash(observation, "error")
        diagnostic = stringify(row["diagnostic"])
        return supplied && redact_hash(supplied) if diagnostic.empty?
        return nil if diagnostic.empty? && supplied.nil?

        {
          "code" => observation&.dig("error", "code") || row.dig("attrs", "reason") || "task_error",
          "summary" => bounded(diagnostic["summary"] || supplied&.fetch("summary", "Task error")),
          "detail" => bounded(diagnostic["detail"] || supplied&.fetch("detail", "Task error"), 500),
          "environment_provenance" => observation&.dig("error", "environment_provenance") || "daemon_runtime"
        }
      end

      def prior_evidence(reason, prior_reason, observation)
        return nil unless prior_reason && prior_reason != reason

        {
          "reason" => prior_reason,
          "observed_at" => observation["observed_at"]
        }
      end

      def evidence_hash(observation, key)
        return nil unless observation

        value = observation[key]
        value.is_a?(Hash) ? redact_hash(stringify(value)) : nil
      end

      def redact_hash(value)
        value.to_h do |key, child|
          redacted = child.is_a?(String) ? Hive::SecretPatterns.redact(child) : child
          [ key, redacted ]
        end
      end

      def bounded(value, max = Hive::DiagnosticHelpers::SUMMARY_MAX)
        single_line = Hive::SecretPatterns.redact(value.to_s).gsub(/[\r\n\t]+/, " ").squeeze(" ").strip
        Hive::DiagnosticHelpers.truncate(single_line, max)
      end

      def stringify(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h.to_h do |key, child|
          normalized = if child.is_a?(Hash)
            stringify(child)
          elsif child.is_a?(Array)
            child.map { |entry| entry.is_a?(Hash) ? stringify(entry) : entry }
          else
            child
          end
          [ key.to_s, normalized ]
        end
      end

      def canonical(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
        when Array
          value.map { |child| canonical(child) }
        else
          value
        end
      end

      def coerce_time(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      end
    end
  end
end
