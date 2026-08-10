require "agent_cli_runtime/version"
require "agent_cli_runtime/errors"
require "agent_cli_runtime/values"

module AgentCliRuntime
  DIAGNOSTIC_BYTES = 512
end

require "agent_cli_runtime/redactor"
require "agent_cli_runtime/usage_extractors"
require "agent_cli_runtime/profile"
require "agent_cli_runtime/profiles"
require "agent_cli_runtime/probe"
require "agent_cli_runtime/runtime"
require "agent_cli_runtime/cli"

module AgentCliRuntime
  module_function

  def compile(request)
    Runtime.compile(request)
  end

  def prepare!(profile)
    Runtime.prepare!(profile)
  end

  def require_capability!(profile, capability)
    Runtime.require_capability!(profile, capability)
  end

  def extract_usage(profile, event)
    Runtime.extract_usage(profile, event)
  end

  def observe(profile, result)
    Runtime.observe(profile, result)
  end

  def probe(profile, home: nil, env: ENV)
    Probe.call(profile, home: home, env: env)
  end

  def probe_all(home: nil, env: ENV)
    Probe.all(home: home, env: env)
  end
end
