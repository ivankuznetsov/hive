require "hive/agent_skills/adapters/claude"
require "hive/agent_profiles"

module Hive
  module AgentSkills
    module Adapters
      class Registry
        ADAPTERS = {
          "claude" => Claude
        }.freeze

        def initialize(**options)
          @options = options
          @instances = {}
        end

        def fetch(agent)
          name = agent.to_s
          klass = Hive::AgentProfiles.support_for(name)&.const_get(:SetupAdapter, false) || ADAPTERS.fetch(name) do
            raise Hive::ConfigError, "no agent-skills adapter for #{name.inspect}"
          end
          @instances[name] ||= klass.new(**@options)
        end
      end
    end
  end
end
