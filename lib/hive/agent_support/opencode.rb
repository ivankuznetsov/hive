require "json"
require "hive/agent_support"

module Hive::AgentSupport::OpenCode
  autoload :Configuration, "hive/agent_support/opencode/configuration"
  autoload :Execution, "hive/agent_support/opencode/execution"
  autoload :LaunchPolicy, "hive/agent_support/opencode/launch_policy"
  autoload :Mcp, "hive/agent_support/opencode/mcp"
  autoload :Observation, "hive/agent_support/opencode/observation"
  autoload :Skills, "hive/agent_support/opencode/skills"
  autoload :SetupAdapter, "hive/agent_support/opencode/setup_adapter"
  PORTABLE_MANAGED_RUNTIME = true
  # OpenCode 2.x serves CLI commands from one shared per-user background
  # server on a fixed loopback port, starting it when absent. That server was
  # started with some other command's environment, so an attached command's
  # OPENCODE_PERMISSION and OPENCODE_CONFIG_CONTENT are not guaranteed to
  # apply, a command with a different XDG identity fails because the port is
  # taken, and a server one command started outlives it. `--standalone` gives
  # the command a private server that ends with it. OpenCode 1.x has no such
  # flag, so Hive passes it only when the binary's own help advertises it. The
  # check is local rather than the agent-cli-runtime helper because installed
  # Hive must keep working against the published 0.2.4 component.
  PRIVATE_SERVER_FLAG = "--standalone"
  PRIVATE_SERVER_ADVERTISEMENT = /(?:\A|[\s,])#{Regexp.escape(PRIVATE_SERVER_FLAG)}(?:[\s,=\[]|$)/
  # Matches the OpenCode profile's version-check bound: Bun-backed startup can
  # exceed ten seconds under sustained host I/O.
  PRIVATE_SERVER_PROBE_TIMEOUT_SECONDS = 30

  module_function

  # The private-server arguments a CLI whose help text is +help+ accepts.
  def private_server_arguments(help)
    help.to_s.match?(PRIVATE_SERVER_ADVERTISEMENT) ? [ PRIVATE_SERVER_FLAG ].freeze : [].freeze
  end

  # The private-server arguments for an `opencode run` of +executable+, read
  # from its own `run --help` (which starts no server). A binary that cannot
  # spawn or exits nonzero is left for the run itself to report; a help that
  # hangs fails the launch rather than risk attaching to a shared server.
  def private_server_launch_arguments(executable, environment: ENV.to_h)
    out, err, status = AgentCliRuntime::Profiles.fetch(:opencode).capture_local(
      "run", "--help", env: environment, executable: executable.to_s,
      timeout_sec: PRIVATE_SERVER_PROBE_TIMEOUT_SECONDS
    )
    status.success? ? private_server_arguments("#{out}\n#{err}") : [].freeze
  rescue Timeout::Error
    raise Hive::AgentError,
          "`#{File.basename(executable.to_s)} run --help` timed out after " \
          "#{PRIVATE_SERVER_PROBE_TIMEOUT_SECONDS}s; cannot tell whether it needs #{PRIVATE_SERVER_FLAG}"
  rescue SystemCallError
    [].freeze
  end

  # A self-spawning launcher's run request (Hive::Mcp.compile), with the
  # private server its executable advertises.
  def spawn_request(request)
    arguments = private_server_launch_arguments(request.executable || request.profile.bin) -
      request.trusted_cli_arguments
    return request if arguments.empty?

    request.with(trusted_cli_arguments: request.trusted_cli_arguments + arguments)
  end

  def credential_path(home: nil)
    AgentCliRuntime::Profiles.opencode_auth_path(home:, env: ENV)
  end
  def configuration = (@configuration ||= Configuration.new)
  def handles_add_dirs? = true

  # An OpenCode author must not inherit a project's broader shell/edit scope.
  # Its only permitted write is the controller-consumed draft, and the draft's
  # validated presence lets the process owner end a trailing detached turn.
  def open_pr_launch_kwargs(expected_output:, completion_probe:)
    {
      permission_kwargs: {
        explicit_permission_spec: {
          "preset" => "scoped",
          "tools" => [ "Edit(#{File.expand_path(expected_output)})" ]
        }
      },
      agent_kwargs: { completion_probe: }
    }
  end

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
