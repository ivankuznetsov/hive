require "hive/agent_runtime"
require "hive/config"

module Hive
  module Patrol
    # Builds the provider-specific context and turn envelope used by every
    # Patrol spawn. Launch admission is count-based and does not inspect token
    # estimates or streamed token totals.
    module AgentLaunch
      module_function

      def prepare(profile:, role:, cfg: nil,
                  routing_arguments: nil)
        cli_flags = minimal_context_flags(profile, role)
        if claude?(profile) && cfg && routing_arguments.nil?
          cli_flags.concat(Hive::Config.claude_cli_flags(cfg))
        end
        {
          cli_flags: cli_flags,
          max_turns: review_turn_limit(profile, role)
        }
      end

      def minimal_context_flags(profile, role)
        return [] unless claude?(profile)

        Hive::AgentRuntime.require_capability!(
          profile, "patrol_#{role}_context".to_sym
        ).arguments.dup
      end
      private_class_method :minimal_context_flags

      def review_turn_limit(profile, role)
        4 if claude?(profile) && role.to_sym == :review
      end
      private_class_method :review_turn_limit

      def claude?(profile)
        Hive::AgentSupport.supports?(profile, :Interactive)
      end
      private_class_method :claude?
    end
  end
end
