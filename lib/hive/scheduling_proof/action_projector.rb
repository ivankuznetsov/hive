require "shellwords"
require "hive/scheduling_proof/reason"

module Hive
  module SchedulingProof
    module ActionProjector
      SAFE_VERBS = %w[
        brainstorm plan develop open-pr review artifacts finalize archive approve run
      ].freeze
      FORBIDDEN_TOKENS = %w[--force --yes --recover-merged-error-reason].freeze
      NO_SAFE_REASONS = %w[
        accounting_inconsistent daemon_not_running daemon_stale
        live_evidence_unavailable legacy_policy_exhausted project_dropped
      ].freeze

      module_function

      def project(reason:, action_key:, command:, stage:, task_generation:, attempt_id:,
                  authoritative_action: nil)
        preconditions = {
          "stage" => stage.to_s,
          "task_generation" => task_generation,
          "attempt_id" => attempt_id
        }
        reason = Reason.normalize(reason)
        return build("no_safe_action", "No safe scheduling action is available.", nil, true, preconditions) if NO_SAFE_REASONS.include?(reason)

        supplied = normalize_authoritative_action(authoritative_action)
        if supplied
          safe = safe_command(supplied["command"])
          return build(supplied.fetch("kind", "wait"), supplied.fetch("text", "Wait for scheduler state to change."),
                       safe, supplied.fetch("requires_confirmation", !safe.nil?), preconditions)
        end

        safe = safe_command(command)
        kind, text = action_copy(reason, action_key, safe)
        safe = nil if kind == "no_safe_action"
        build(kind, text, safe, !safe.nil?, preconditions)
      end

      def safe_command(command)
        return nil if command.nil? || command.to_s.strip.empty?

        argv = Shellwords.split(command.to_s)
        return nil unless argv.first == "hive"
        return nil unless SAFE_VERBS.include?(argv[1])
        return nil if (argv & FORBIDDEN_TOKENS).any?
        return nil if argv.any? { |token| token.match?(/[;&|`\n\r]/) }

        Shellwords.join(argv)
      rescue ArgumentError
        nil
      end

      def normalize_authoritative_action(action)
        return nil unless action.is_a?(Hash)

        action.transform_keys(&:to_s)
      end

      def action_copy(reason, action_key, safe)
        return [ "wait", "Wait for the current attempt to finish." ] if reason == "executing"
        return [ "answer", "Provide the requested input using the existing guarded command." ] if action_key.to_s == "needs_input" && safe
        return [ "retry", "Retry through the existing guarded recovery command." ] if action_key.to_s.start_with?("recover_") && safe
        return [ "wait", "Wait for the current scheduling hold to clear." ] if wait_reason?(reason)
        return [ "manual", "Run the existing guarded task command after confirming current state." ] if safe

        [ "no_safe_action", "Inspect current durable evidence before intervening." ]
      end

      def wait_reason?(reason)
        %w[
          needs_input edit_debounce dependency_wait retry_wait cooldown quarantined
          provider_circuit_open provider_unavailable global_capacity project_capacity
          daily_capacity merge_wait babysitter_blocked archive_guard dispatch_pending
          already_in_flight no_candidate
        ].include?(reason)
      end

      def build(kind, text, command, confirmation, preconditions)
        {
          "kind" => kind,
          "text" => text,
          "command" => command,
          "requires_confirmation" => confirmation == true,
          "preconditions" => preconditions
        }
      end
    end
  end
end
