require_relative "test_helper"

class AgentCliRuntimeOpenCodeOfflineSmokeTest < Minitest::Test
  DEFAULT_ROUTE = "opencode/hy3-free"
  DEFAULT_VARIANT = "high"

  def test_installed_cli_satisfies_the_offline_preparation_contract_without_a_run
    binary = installed_binary
    unless binary
      message = "OpenCode is not installed; the 1.18.16+ offline smoke cannot run"
      if ENV["AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_REQUIRED"] == "1"
        flunk message
      end
      skip message
    end

    route = ENV.fetch(
      "AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_ROUTE", DEFAULT_ROUTE
    )
    variant = ENV.fetch(
      "AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_VARIANT", DEFAULT_VARIANT
    )
    parsed_route = AgentCliRuntime::Route.parse(route)

    Dir.mktmpdir("agent-cli-runtime-opencode-offline") do |dir|
      work = File.join(dir, "work")
      root = File.join(dir, "invocation")
      calls = File.join(dir, "calls.jsonl")
      wrapper = File.join(dir, "opencode-offline-wrapper")
      FileUtils.mkdir_p(work)
      write_guarded_wrapper(wrapper, binary, calls, parsed_route.provider)

      env = ENV.to_h.merge(
        "AGENT_CLI_RUNTIME_OPENCODE_BIN" => wrapper,
        # This is evidence that a caller-selected credential environment key
        # is configured. The guarded wrapper can execute only local inventory
        # commands, so this placeholder can never reach a model request.
        "OPENCODE_API_KEY" => "offline-probe-placeholder"
      )
      prepared = AgentCliRuntime.prepare!(
        AgentCliRuntime::OpenCodePreparationRequest.new(
          request: AgentCliRuntime::Request.new(
            profile: :opencode,
            prompt: "this prompt must never execute",
            permission_mode: "workspace-write",
            model: route,
            effort: variant
          ),
          working_directory: work,
          invocation_root: root,
          configuration: {
            "provider" => { parsed_route.provider => {} }
          },
          credential_environment_keys: [ "OPENCODE_API_KEY" ],
          additional_write_roots: [ work ]
        ),
        env: env
      )

      assert prepared.probe_result.ready
      assert_operator Gem::Version.new(prepared.probe_result.version),
                      :>=, Gem::Version.new("1.18.16")
      assert_equal route, prepared.requested_route.to_s
      assert_includes prepared.probe_result.available_variants, variant
      assert_equal wrapper, prepared.invocation.argv.first
      assert_equal "true",
                   prepared.environment.fetch("OPENCODE_DISABLE_MODELS_FETCH")

      policy = JSON.parse(File.read(prepared.configuration_path))
                   .fetch("permission")
      assert_equal "deny", policy.fetch("*")
      assert_equal "deny", policy.fetch("bash")
      assert_equal "deny", policy.dig("edit", "*")
      assert_equal "allow", policy.dig("edit", "**")
      refute policy.fetch("edit").keys.any? { |pattern| pattern.start_with?(work) }
      assert_equal "deny", policy.dig("external_directory", "*")

      observed = File.readlines(calls, chomp: true).map { |line| JSON.parse(line) }
      assert_equal [
        [ "--version" ],
        [ "run", "--help" ],
        [ "export", "--help" ],
        [ "auth", "list" ],
        [ "models", parsed_route.provider, "--verbose" ]
      ], observed
      refute observed.any? { |arguments| arguments.first == "run" && arguments != [ "run", "--help" ] }
    ensure
      prepared&.cleanup!
      refute File.exist?(root), "offline smoke must clean its invocation root"
    end
  end

  private

  def installed_binary
    explicit = ENV["AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_BIN"].to_s
    unless explicit.empty?
      path = File.expand_path(explicit)
      return path if File.file?(path) && File.executable?(path)

      flunk "AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_BIN is not executable"
    end

    executable = AgentCliRuntime::Profiles.fetch(:opencode).bin(env: ENV)
    if executable.include?(File::SEPARATOR)
      return File.expand_path(executable) if File.file?(executable) && File.executable?(executable)

      return nil
    end

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      candidate = File.join(directory, executable)
      return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  def write_guarded_wrapper(path, binary, calls, provider)
    allowed = [
      [ "--version" ],
      [ "run", "--help" ],
      [ "export", "--help" ],
      [ "auth", "list" ],
      [ "models", provider, "--verbose" ]
    ]
    write_executable(path, <<~RUBY)
      #!/usr/bin/ruby --disable-gems
      require "json"
      allowed = #{allowed.inspect}
      File.open(#{calls.dump}, "a", 0o600) do |file|
        file.puts(JSON.generate(ARGV))
      end
      unless allowed.include?(ARGV)
        warn "offline OpenCode smoke refused a non-inspection command"
        exit 64
      end
      exec(#{binary.dump}, *ARGV)
    RUBY
  end
end
