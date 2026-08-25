require "agent_cli_runtime/version"
require "agent_cli_runtime/errors"
require "agent_cli_runtime/values"

module AgentCliRuntime
  DIAGNOSTIC_BYTES = 512
end

require "agent_cli_runtime/redactor"
require "agent_cli_runtime/usage_extractors"
require "agent_cli_runtime/error_extractors"
require "agent_cli_runtime/opencode/result_parser"
require "agent_cli_runtime/profile"
require "agent_cli_runtime/profiles"
require "agent_cli_runtime/probe"
require "agent_cli_runtime/runtime"
require "agent_cli_runtime/opencode/probe"
require "agent_cli_runtime/opencode/permissions"
require "agent_cli_runtime/opencode/overlay"
require "agent_cli_runtime/opencode/inspection"
require "agent_cli_runtime/cli"

module AgentCliRuntime
  module_function

  def compile(request)
    Runtime.compile(request)
  end

  def prepare!(profile, env: ENV)
    Runtime.prepare!(profile, env:)
  end

  def require_capability!(profile, capability)
    Runtime.require_capability!(profile, capability)
  end

  def extract_usage(profile, event)
    Runtime.extract_usage(profile, event)
  end

  def extract_provider_error(profile, event)
    Runtime.extract_provider_error(profile, event)
  end

  def observe(profile, result)
    Runtime.observe(profile, result)
  end

  def parse_run(profile, stdout:)
    Runtime.parse_run(profile, stdout:)
  end

  def prepare_inspection(prepared, parsed_run)
    OpenCode::Inspection.compile(prepared, parsed_run)
  end

  def normalize(profile, captured, requested_route:)
    Runtime.normalize(profile, captured, requested_route:)
  end

  def probe(profile, home: nil, env: ENV)
    if profile.is_a?(ProbeRequest)
      OpenCode::Probe.call(profile, env: env)
    else
      Probe.call(profile, home: home, env: env)
    end
  end

  def probe_all(home: nil, env: ENV)
    Probe.all(home: home, env: env)
  end
end
