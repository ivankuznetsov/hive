require "hive/plan_review"

module Hive
  module PlanReview
    module Adapters
      module Base
        OUTCOMES = %w[
          success partial_coverage unsupported provider_limit timeout retryable_failure terminal_failure
        ].freeze
        KINDS = %w[primary adversarial verification].freeze

        Request = Data.define(
          :plan_path, :plan_digest, :document_type, :level, :required_coverage,
          :policy_fingerprint, :planner_identity, :reviewer, :output_directory,
          :timeout_sec, :attempt_id, :kind, :project_root
        ) do
          def initialize(plan_path:, plan_digest:, document_type:, level:, required_coverage:,
                         policy_fingerprint:, planner_identity:, reviewer:, output_directory:,
                         timeout_sec:, attempt_id:, kind: "primary", project_root: nil)
            normalized_level = Hive::PlanReview.level!(level)
            normalized_kind = kind.to_s
            raise ArgumentError, "unknown plan review adapter kind #{kind.inspect}" unless KINDS.include?(normalized_kind)
            unless plan_digest.to_s.match?(/\A[0-9a-f]{64}\z/) &&
                   policy_fingerprint.to_s.match?(/\A[0-9a-f]{64}\z/) &&
                   attempt_id.to_s.match?(/\Apra-[0-9a-f]{64}\z/)
              raise ArgumentError, "plan review adapter identity is malformed"
            end
            unless timeout_sec.is_a?(Integer) && timeout_sec.positive?
              raise ArgumentError, "plan review adapter timeout must be positive"
            end
            super(
              plan_path: File.expand_path(plan_path),
              plan_digest: plan_digest.to_s.freeze,
              document_type: document_type.to_s.freeze,
              level: normalized_level.freeze,
              required_coverage: Array(required_coverage).map(&:to_s).uniq.freeze,
              policy_fingerprint: policy_fingerprint.to_s.freeze,
              planner_identity: freeze_hash(planner_identity),
              reviewer: freeze_hash(reviewer),
              output_directory: File.expand_path(output_directory),
              timeout_sec: timeout_sec,
              attempt_id: attempt_id.to_s.freeze,
              kind: normalized_kind.freeze,
              project_root: project_root && File.expand_path(project_root)
            )
            freeze
          end

          private

          def freeze_hash(value)
            value.to_h { |key, child| [ key.to_s.freeze, child.to_s.freeze ] }.freeze
          end
        end

        Result = Data.define(
          :outcome, :findings, :coverage, :selected_lenses, :residual_evidence,
          :diagnostic, :retry_at, :route_receipt
        ) do
          def initialize(outcome:, findings: [], coverage: [], selected_lenses: [],
                         residual_evidence: [], diagnostic: nil, retry_at: nil,
                         route_receipt: {})
            normalized = outcome.to_s
            raise ArgumentError, "unknown plan review outcome #{outcome.inspect}" unless OUTCOMES.include?(normalized)
            super(
              outcome: normalized.freeze,
              findings: Array(findings).freeze,
              coverage: Array(coverage).freeze,
              selected_lenses: Array(selected_lenses).freeze,
              residual_evidence: Array(residual_evidence).freeze,
              diagnostic: diagnostic&.to_s&.freeze,
              retry_at: retry_at&.to_s&.freeze,
              route_receipt: route_receipt.to_h.freeze
            )
            freeze
          end

          def successful? = %w[success partial_coverage].include?(outcome)

          def to_h
            {
              "outcome" => outcome,
              "findings" => findings.map { |finding| finding.respond_to?(:to_h) ? finding.to_h : finding },
              "coverage" => coverage,
              "selected_lenses" => selected_lenses,
              "residual_evidence" => residual_evidence,
              "diagnostic" => diagnostic,
              "retry_at" => retry_at,
              "route_receipt" => route_receipt
            }
          end
        end
      end
    end
  end
end
