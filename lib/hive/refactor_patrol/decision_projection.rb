require "hive/errors"
require "hive/modules/migration/patrol_decision_projection"

module Hive
  module RefactorPatrol
    module DecisionProjection
      PHASES = %w[discovery action].freeze

      module_function

      def candidate_input(job_id:, phase:)
        validate_input!(
          {
            "kind" => "candidate",
            "job_id" => job_id.to_s,
            "phase" => phase.to_s
          }.freeze
        )
      end

      def operation_input(job_id:, phase:, operation:)
        validate_input!(
          {
            "kind" => "operation",
            "job_id" => job_id.to_s,
            "phase" => phase.to_s,
            "operation" => operation.to_s
          }.freeze
        )
      end

      def project(input)
        input = validate_input!(input)
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "architecture-patrol",
          rationale: "due",
          job_id: input.fetch("job_id"),
          phase: input.fetch("phase")
        )
      end

      def validate_input!(input)
        malformed! unless input.is_a?(Hash)
        expected = input["kind"] == "candidate" ?
          %w[job_id kind phase] :
          %w[job_id kind operation phase]
        malformed! unless %w[candidate operation].include?(input["kind"]) &&
                          input.keys.sort == expected &&
                          !input["job_id"].to_s.empty? &&
                          PHASES.include?(input["phase"].to_s)
        if input["kind"] == "operation"
          malformed! if input["operation"].to_s.empty?
        end
        input
      end

      def malformed!
        raise Hive::ConfigError,
              "architecture patrol selection input is malformed"
      end
      private_class_method :malformed!
    end
  end
end
