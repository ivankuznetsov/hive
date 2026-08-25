require "json"
require "hive/agent_support"

module Hive::AgentSupport::OpenCode
  autoload :Configuration, "hive/agent_support/opencode/configuration"
  autoload :Execution, "hive/agent_support/opencode/execution"
  autoload :LaunchPolicy, "hive/agent_support/opencode/launch_policy"
  autoload :Observation, "hive/agent_support/opencode/observation"
  autoload :Skills, "hive/agent_support/opencode/skills"
  autoload :SetupAdapter, "hive/agent_support/opencode/setup_adapter"
  PORTABLE_MANAGED_RUNTIME = true

  module_function

  def credential_path(home: nil)
    AgentCliRuntime::Profiles.opencode_auth_path(home:, env: ENV)
  end
  def configuration = (@configuration ||= Configuration.new)
  def handles_add_dirs? = true

  def verify_launch_skill(profile:, invocation:, project_root:)
    status, evidence = profile.verify_skill(invocation, project_root:)
    return invocation if status == :present

    raise Hive::AgentError,
          "OpenCode skill readiness failed for #{invocation}: #{evidence}"
  end

  def execution_identity(model)
    value = model.to_s
    value.include?("/") ? value.split("/", 2) : [ nil, value ]
  end

  def downstream_model(stage:, execute_identity:, provider_changed:)
    return unless stage == "open_pr" && !provider_changed

    model = execute_identity.respond_to?(:model) ? execute_identity.model :
      execute_identity["model"] || execute_identity[:model]
    [ model, true ]
  end

  def commit_completion_candidate?(result)
    result && result[:exit_code] == 0 &&
      result[:normalized_outcome_kind] == :malformed_output
  end

  def record_observation(host:, stage:, result:)
    normalized_usage = result[:normalized_outcome]&.usage || result[:usage]
    host.observe_route!(
      stage:,
      requested_route: result.fetch(:requested_route),
      actual_route: result[:actual_route],
      resolution_status: result.fetch(:route_resolution_status),
      outcome_kind: result.fetch(:normalized_outcome_kind),
      usage: normalized_usage,
      observation_id: result[:hive_observation_id]
    )
  end

  def default_model(cfg:, project_root: nil, **)
    inline = cfg&.dig("agents", "opencode", "config")
    if inline
      unless inline.is_a?(Hash)
        raise Hive::ImplementationIdentity::ResolutionError,
              "agents.opencode.config must be a JSON object"
      end
      return AgentCliRuntime::Route.parse(inline["model"]).to_s
    end

    path = cfg&.dig("agents", "opencode", "config_path").to_s
    path = File.expand_path(path, project_root || cfg["project_root"]) if
      !path.empty? && !File.absolute_path?(path)
    if path.empty?
      raise Hive::ImplementationIdentity::ResolutionError,
            "OpenCode requires models.<role>.model or an explicit " \
            "agents.opencode.config_path default"
    end
    document = JSON.parse(File.binread(path))
    unless document.is_a?(Hash)
      raise Hive::ImplementationIdentity::ResolutionError,
            "OpenCode selected configuration must be a JSON object"
    end
    AgentCliRuntime::Route.parse(document["model"]).to_s
  rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, ArgumentError => error
    raise Hive::ImplementationIdentity::ResolutionError,
          "could not inspect explicit OpenCode default model: #{error.message}"
  end

  def plan_review_launch_kwargs(**)
    policy = Hive::AgentRuntime::OpenCodePermissionPolicy.new(
      "*" => "deny",
      "read" => {
        "*" => "allow", "*.env" => "deny", "*.env.*" => "deny",
        "*.env.example" => "allow"
      },
      "glob" => "allow", "grep" => "allow", "list" => "allow",
      "lsp" => "allow", "skill" => "allow",
      "external_directory" => { "*" => "deny" },
      "edit" => { "*" => "deny", "**" => "allow" },
      "bash" => "allow", "webfetch" => "allow", "websearch" => "allow",
      "task" => "deny", "question" => "deny"
    )
    {
      permission_mode: nil, allowed_tools: nil, disallowed_tools: nil,
      permission_policy: policy
    }
  end
end
