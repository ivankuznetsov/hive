require "hive/proposals"
require "hive/proposals/configuration_row"

module Hive
  module Proposals
    # Resolves a named evaluator only at controller admission. The returned
    # binding is copied into the durable attempt and later source receipt, so
    # replay verifies historical admission without consulting mutable config.
    class EvaluatorAuthority
      ROW_KEYS = EVALUATOR_CONFIG_KEYS

      def initialize(config)
        @config = Proposals.stringify(config.fetch("proposals", config))
      end

      def bind!(identity:, workflow:, stage:, agent_profile:)
        identity = Proposals.label!(identity, label: "proposal evaluator identity")
        row = @config.fetch("evaluators", {}).fetch(identity, nil)
        raise Unauthorized, "proposal evaluator is not configured" unless row

        row = validate_row!(row)
        match!(row, "workflows", workflow)
        match!(row, "stages", stage)
        match!(row, "agent_profiles", agent_profile)
        Proposals.deep_copy_freeze(
          "id" => identity,
          "fingerprint" => Proposals.digest(row),
          "configuration_fingerprint" => configuration_fingerprint,
          "admission" => row
        )
      end

      def configuration_fingerprint
        @configuration_fingerprint ||= Proposals.digest(@config)
      end

      private

      def validate_row!(value)
        ConfigurationRow.evaluator!(value)
      end

      def match!(row, key, value)
        allowed = row.fetch(key)
        actual = value.to_s
        return if allowed.include?(actual)

        raise Unauthorized, "proposal evaluator is not admitted for #{key.tr('_', ' ')}"
      end
    end
  end
end
