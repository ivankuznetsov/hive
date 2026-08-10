require "hive/agent_runtime"

module Hive
  module Patrol
    # Builds the provider-specific safety envelope used by every patrol spawn.
    # The explicit prompt is charged at one token per byte, a conservative
    # upper bound for byte-level tokenizers, before the provider receives it.
    module AgentLaunch
      module_function

      def prepare(profile:, prompt:, role:)
        initial_context = profile.respond_to?(:initial_context_tokens) ? profile.initial_context_tokens : 0
        {
          cli_flags: minimal_context_flags(profile, role),
          minimum_tokens: initial_context + prompt.to_s.bytesize,
          max_turns: review_turn_limit(profile, role)
        }
      end

      def minimal_context_flags(profile, role)
        return [] unless profile.respond_to?(:name) && profile.name == :claude

        Hive::AgentRuntime.require_capability!(
          profile, "patrol_#{role}_context".to_sym
        ).arguments.dup
      end
      private_class_method :minimal_context_flags

      def review_turn_limit(profile, role)
        4 if profile.respond_to?(:name) && profile.name == :claude && role.to_sym == :review
      end
      private_class_method :review_turn_limit
    end
  end
end
