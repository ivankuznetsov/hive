require "agent_cli_runtime"

module Hive
  module AgentProfiles
    # Deprecated compatibility name. Provider decoding is implemented by the
    # published package and these constants are the same callable objects.
    UsageExtractors = AgentCliRuntime::UsageExtractors
  end
end
