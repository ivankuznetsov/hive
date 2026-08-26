require "hive/agent_profiles"

module Hive
  module AgentSkills
    module Adapters
      class Registry
        def initialize(**options)
          @options = options
          @instances = {}
        end

        def fetch(agent)
          name = agent.to_s
          klass = Hive::AgentProfiles.support_for(name)&.const_get(:SetupAdapter, false) ||
            raise(Hive::ConfigError, "no agent-skills adapter for #{name.inspect}")
          @instances[name] ||= klass.new(**@options)
        end
      end
    end
  end
end
