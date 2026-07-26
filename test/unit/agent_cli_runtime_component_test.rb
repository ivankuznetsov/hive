require "test_helper"

component_root = File.expand_path("../../components/agent-cli-runtime", __dir__)
$LOAD_PATH.unshift File.join(component_root, "lib")
require "agent_cli_runtime"

class AgentCliRuntimeComponentTest < Minitest::Test
  COMPONENT_ROOT =
    File.expand_path("../../components/agent-cli-runtime", __dir__)

  def test_public_package_clean_loads_without_hive
    script = <<~'RUBY'
      require "agent_cli_runtime"
      abort "loaded Hive unexpectedly" if defined?(Hive)
      abort "wrong version" unless AgentCliRuntime::VERSION == "0.1.0"
      puts AgentCliRuntime::Profiles.names.join(",")
    RUBY
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(
        Gem.ruby,
        "-I#{File.join(COMPONENT_ROOT, 'lib')}",
        "-e",
        script
      )
    end

    assert status.success?, err
    assert_equal "claude,codex,pi,grok\n", out
  end

  def test_builtin_compile_transport_matches_hive_boundary
    %i[claude codex pi grok].each do |provider|
      public_invocation = AgentCliRuntime.compile(
        AgentCliRuntime::Request.new(
          profile: AgentCliRuntime::Profiles.fetch(provider),
          prompt: "inspect"
        )
      )
      hive_invocation = Hive::AgentRuntime.compile(
        Hive::AgentRuntime::Request.new(
          profile: Hive::AgentProfiles.lookup(provider),
          prompt: "inspect"
        )
      )

      assert_equal hive_invocation.argv, public_invocation.argv, provider
      if hive_invocation.stdin_data.nil?
        assert_nil public_invocation.stdin_data, provider
      else
        assert_equal hive_invocation.stdin_data, public_invocation.stdin_data, provider
      end
      assert_equal hive_invocation.provider, public_invocation.provider, provider
      assert_equal hive_invocation.launcher_identity,
                   public_invocation.launcher_identity,
                   provider
    end
  end

  def test_builtin_usage_extraction_matches_hive_boundary
    events = {
      claude: {
        "type" => "result",
        "usage" => {
          "input_tokens" => 3,
          "output_tokens" => 2,
          "cache_read_input_tokens" => 1
        },
        "model" => "claude-sonnet"
      },
      codex: {
        "type" => "turn.completed",
        "usage" => { "input_tokens" => 4, "output_tokens" => 3 }
      },
      pi: {
        "type" => "result",
        "usage" => { "promptTokens" => 5, "completionTokens" => 4 }
      },
      grok: { "type" => "end" }
    }

    events.each do |provider, event|
      expected = Hive::AgentRuntime.extract_usage(
        Hive::AgentProfiles.lookup(provider),
        event
      )
      actual = AgentCliRuntime.extract_usage(provider, event)
      expected.nil? ? assert_nil(actual, provider) : assert_equal(expected, actual, provider)
    end
  end

  def test_package_only_change_does_not_enter_hive_dependency_graph
    spec = Gem::Specification.load(File.expand_path("../../hive.gemspec", __dir__))

    refute(
      spec.runtime_dependencies.any? do |dependency|
        dependency.name == "agent-cli-runtime"
      end
    )
    refute File.read(File.expand_path("../../lib/hive.rb", __dir__))
               .include?('require "agent_cli_runtime"')
  end
end
