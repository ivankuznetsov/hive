require "hive"

module Hive
  module PlanReview
    SCHEMA = "hive-plan-review".freeze
    SCHEMA_VERSION = 1
    LEVELS = %w[skip standard mandatory].freeze
    LEVEL_RANK = LEVELS.each_with_index.to_h.freeze
    CLASSIFIER_VERSION = 1
    # Bump when the reviewer prompt/output contract changes in a way that
    # requires an identical plan to be judged again under the new contract.
    ADAPTER_CONTRACT_VERSION = 2
    RECOVERY_RESET_ROUTE_KEYS = %w[
      role requested actual capability_result
      independence_verified independence_reason
    ].freeze

    class Error < Hive::Error; end
    class InvalidPlan < Error; end
    class InvalidRecord < Error; end
    class StaleObservation < Error; end
    class InvalidAction < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class StaleDecision < Error
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end
    class ConflictingDecision < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class UnauthorizedAction < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class TransitionBlocked < Hive::WrongStage
      attr_reader :review_id, :review_state, :required_action, :blockers

      def initialize(message, review_id: nil, review_state: nil, required_action: nil,
                     blockers: [], **stage_context)
        super(message, **stage_context)
        @review_id = review_id
        @review_state = review_state
        @required_action = required_action
        @blockers = Array(blockers).freeze
      end
    end

    module_function

    def level!(value, label: "plan review level")
      normalized = value.to_s.strip
      return normalized if LEVEL_RANK.key?(normalized)

      raise Hive::ConfigError,
            "#{label} must be one of #{LEVELS.join(', ')}; got #{value.inspect}"
    end

    def higher_level(*levels)
      levels.compact.map { |level| level!(level) }.max_by { |level| LEVEL_RANK.fetch(level) }
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def recovery_reset_route(route, attributes = {})
      route.slice(*RECOVERY_RESET_ROUTE_KEYS).merge(
        "outcome" => "retryable_failure", "retry_at" => nil,
        "recovery_reset" => true
      ).merge(attributes)
    end
  end
end
