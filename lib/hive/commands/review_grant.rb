require "json"
require "hive/schemas"
require "hive/task_resolver"
require "hive/review_budget"
require "hive/recovery/api"

module Hive
  module Commands
    # Explicit operator decision. Scheduler actions cannot allocate fix budget.
    class ReviewGrant
      include Hive::Schemas::EnvelopeEmitter

      def initialize(target, project: nil, passes: nil, reason: nil,
                     evidence_token: nil, json: false, coordinator: nil)
        @target, @project, @passes, @reason = target, project, passes, reason
        @evidence_token, @json, @coordinator = evidence_token, json, coordinator
      end

      def call
        call_with_envelope do
          validate!
          task = Hive::TaskResolver.new(@target, project_filter: @project).resolve
          result = Hive::Recovery::API.grant_review!(
            task: task, project: @project, passes: @passes, reason: @reason,
            evidence_token: @evidence_token, coordinator: @coordinator
          )
          payload = result.merge("schema" => envelope_schema, "schema_version" => 1, "ok" => true)
          puts(@json ? JSON.generate(payload) :
            "#{task.slug}: review grant #{payload.fetch('decision_id')} #{payload.fetch('state')}; #{payload.fetch('remediation')}")
          payload
        end
      end

      def envelope_schema = "hive-review-grant"
      def envelope_serialization_failure_policy = :raise

      def envelope_extras_for(error)
        { "refusal_reason" => error.respond_to?(:reason) ? error.reason : envelope_error_kind(error),
          "remediation" => error.respond_to?(:remediation) ? error.remediation :
            "Use an operator terminal, inspect the failure and refresh hive status --operational --json before retrying." }
      end

      def envelope_error_kind(error)
        if error.is_a?(Hive::ReviewBudget::Refused)
          return "decision_conflict" if error.reason == "decision_conflict"
          return "unsafe_state" if error.reason == "unsafe_state"
          return "usage" if %w[invalid_passes invalid_reason].include?(error.reason)
          return "stale_evidence" if %w[head_changed evidence_changed stale_evidence].include?(error.reason)
          return "evidence_unavailable"
        end
        return error.error_kind if error.respond_to?(:error_kind)

        case error
        when Hive::UsageError then "usage"
        when Hive::AmbiguousSlug then "ambiguous_target"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::ConfigError then "config"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      private

      def validate!
        raise Hive::UsageError, "--project is required" if @project.to_s.strip.empty?
        unless @evidence_token.is_a?(String) && @evidence_token.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::UsageError, "--evidence-token requires the grant token from current operational status"
        end
        decision = Hive::ReviewBudget.normalize_decision(passes: @passes, reason: @reason)
        @passes, @reason = decision.fetch(:passes), decision.fetch(:reason)
      end
    end
  end
end

require "hive/cli_usage_contracts"
Hive::CliUsageContracts.declare("review-grant") do |*_args, **_options|
  { schema: "hive-review-grant", error_kind: "usage" }
end
