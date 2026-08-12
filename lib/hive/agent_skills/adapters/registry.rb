require "hive/agent_skills/adapters/claude"
require "hive/agent_skills/adapters/codex"
require "hive/agent_skills/adapters/grok"
require "hive/agent_skills/adapters/pi"
require "hive/agent_skills/adapters/opencode"

module Hive
  module AgentSkills
    module Adapters
      class Registry
        ADAPTERS = {
          "claude" => Claude,
          "codex" => Codex,
          "grok" => Grok,
          "pi" => Pi,
          "opencode" => OpenCode
        }.freeze

        def initialize(**options)
          @options = options
          @instances = {}
        end

        def fetch(agent)
          name = agent.to_s
          klass = ADAPTERS.fetch(name) do
            raise Hive::ConfigError, "no agent-skills adapter for #{name.inspect}"
          end
          @instances[name] ||= klass.new(**@options)
        end
      end
    end
  end
end
