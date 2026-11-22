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
  # from its own `run --help` (which starts no server).
  def private_server_launch_arguments(executable, environment: ENV.to_h)
    private_server_arguments(run_help(executable, environment:))
  end

  # OpenCode 2.2 removed `run --variant` and `run --dir`: the effort moved into
  # the model (`provider/model#variant`) and the working directory is the
  # process's own. It also removed `export`. Hive compiles the 1.x shape; the
  # contract read from the binary's `run --help` says how to adapt it.
  LEGACY_RUN_FLAGS = %w[--variant --dir].freeze

  RunContract = Data.define(:server_arguments, :legacy_flags) do
    # Only the 1.x CLI has `export --sanitize`.
    def legacy? = legacy_flags.include?("--variant")
  end

  # One `run --help` read for the whole launch. When the help is unavailable
  # the argv is left in its 1.x shape and the run itself reports the problem.
  def run_contract(executable, environment: ENV.to_h)
    help = run_help(executable, environment:)
    legacy = help ? LEGACY_RUN_FLAGS.select { |flag| advertised?(help, flag) } : LEGACY_RUN_FLAGS
    RunContract.new(server_arguments: private_server_arguments(help), legacy_flags: legacy.freeze)
  end

  # Rewrites a compiled 1.x argv for a CLI that lacks the legacy flags. Only
  # OpenCode's own arguments (from +start+, after any sandbox prefix such as
  # bwrap, which has its own `--dir`) are touched.
  def adapt_run_arguments(argv, contract, start: 0)
    argv = argv.dup
    find = ->(flag) { (start...argv.length).find { |index| argv[index] == flag } }
    unless contract.legacy_flags.include?("--variant")
      index = find.call("--variant")
      if index
        variant = argv.delete_at(index + 1)
        argv.delete_at(index)
        model = find.call("--model")
        raise Hive::AgentError, "OpenCode #{variant} variant needs a pinned --model" unless model && argv[model + 1]

        argv[model + 1] = "#{argv[model + 1]}##{variant}"
      end
    end
    unless contract.legacy_flags.include?("--dir")
      index = find.call("--dir")
      argv.slice!(index, 2) if index
    end
    argv
  end

  # 2.x has no `export`; its server API returns the terminal message instead
  # (`GET /api/session/:id/message/:message_id`). Reduce it to the
  # sanitized-export shape the result parser validates: identity and usage
  # only, no message content.
  def session_export(session_id, output)
    document = JSON.parse(output)
    message = document.is_a?(Hash) ? document["data"] : nil
    raise JSON::ParserError, "OpenCode session message must be an object" unless message.is_a?(Hash)

    model = message["model"].is_a?(Hash) ? message["model"] : {}
    record = {
      "id" => message["id"], "sessionID" => session_id, "role" => message["type"],
      "finish" => message["finish"], "providerID" => model["providerID"],
      "modelID" => model["id"], "tokens" => message["tokens"], "cost" => message["cost"]
    }
    JSON.generate("info" => { "id" => session_id }, "messages" => [ { "info" => record } ])
  end

  # The help text of `opencode run`, or nil when the binary cannot spawn or
  # exits nonzero (left for the run itself to report). A help that hangs
  # fails the launch rather than risk attaching to a shared server.
  def run_help(executable, environment:)
    out, err, status = AgentCliRuntime::Profiles.fetch(:opencode).capture_local(
      "run", "--help", env: environment, executable: executable.to_s,
      timeout_sec: PRIVATE_SERVER_PROBE_TIMEOUT_SECONDS
    )
    status.success? ? "#{out}\n#{err}" : nil
  rescue Timeout::Error
    raise Hive::AgentError,
          "`#{File.basename(executable.to_s)} run --help` timed out after " \
          "#{PRIVATE_SERVER_PROBE_TIMEOUT_SECONDS}s; cannot tell whether it needs #{PRIVATE_SERVER_FLAG}"
  rescue SystemCallError
    nil
  end

  def advertised?(help, flag)
    help.to_s.match?(/(?:\A|[\s,])#{Regexp.escape(flag)}(?:[\s,=\[]|$)/)
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
