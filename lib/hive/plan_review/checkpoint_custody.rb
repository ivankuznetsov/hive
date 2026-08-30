require "hive/plan_review/result_parser"

module Hive
  module PlanReview
    module CheckpointCustody
      CONTRACT_VERSION = 1
      BASENAME = "task-projection.checkpoint.json".freeze
      DIAGNOSTIC = "reviewer modified protected artifacts: #{BASENAME}".freeze
      INITIAL_REVIEW_ROLES = ResultParser::INITIAL_REVIEW_RECOVERY_ROLES

      module_function

      # Recover only exact, runner-authored initial-review failures. A
      # versioned reset suppresses later replays of the same lineage; malformed
      # recovery metadata fails closed instead of creating a retry loop.
      def recoverable_routes(routes)
        recoverable_by_role(routes).values_at(*INITIAL_REVIEW_ROLES).compact
      end

      def recoverable?(routes)
        recoverable_by_role(routes).any?
      end

      def recoverable_by_role(routes)
        recoverable = {}
        recovered_roles = {}
        attempted_roles = {}
        Array(routes).reverse_each do |route|
          role = route["role"]
          next unless INITIAL_REVIEW_ROLES.include?(role)

          if route["checkpoint_custody_recovery"] == true
            status = contract_status(route)
            unless status == :stale
              recovered_roles[role] = true
              recoverable.delete(role)
            end
            next
          end
          next if recovered_roles[role]
          next if route["attempt_id"].to_s.empty?
          next if attempted_roles[role]

          attempted_roles[role] = true
          next unless route["outcome"] == "terminal_failure"
          next unless route["diagnostic"] == DIAGNOSTIC
          next unless route["diagnostic_source"] == "runner"

          recoverable[role] = route
        end
        recoverable
      end
      private_class_method :recoverable_by_role

      def contract_status(route)
        return :current if
          Integer(route["checkpoint_custody_contract_version"]) >= CONTRACT_VERSION

        :stale
      rescue ArgumentError, TypeError
        :invalid
      end
      private_class_method :contract_status
    end
  end
end
