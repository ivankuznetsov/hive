require "test_helper"

component_root = File.expand_path("../../components/agent-cli-runtime", __dir__)
$LOAD_PATH.unshift File.join(component_root, "lib")
require "agent_cli_runtime"

class AgentCliRuntimeComponentTest < Minitest::Test
  include HiveTestHelper

  COMPONENT_ROOT =
    File.expand_path("../../components/agent-cli-runtime", __dir__)
  COMPILE_OPTIONS = {
    claude: {
      permission_mode: "bypassPermissions",
      model: "claude-sonnet",
      effort: "high",
      add_dirs: [ "/tmp/work" ],
      allowed_tools: [ "Read" ],
      disallowed_tools: [ "Write" ],
      max_budget_usd: 1.5
    },
    codex: {
      permission_mode: "read-only",
      model: "gpt-5.6-terra",
      effort: "high",
      add_dirs: [ "/tmp/work" ]
    },
    pi: {
      model: "provider/model"
    },
    grok: {
      model: "grok-code",
      effort: "high"
    }
  }.freeze

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

  def test_non_default_builtin_compile_transport_matches_hive_boundary
    COMPILE_OPTIONS.each do |provider, options|
      public_invocation = AgentCliRuntime.compile(
        AgentCliRuntime::Request.new(
          profile: AgentCliRuntime::Profiles.fetch(provider),
          prompt: "inspect",
          **options
        )
      )
      hive_invocation = Hive::AgentRuntime.compile(
        Hive::AgentRuntime::Request.new(
          profile: Hive::AgentProfiles.lookup(provider),
          prompt: "inspect",
          **options
        )
      )

      assert_equal hive_invocation.argv, public_invocation.argv, provider
      if hive_invocation.stdin_data.nil?
        assert_nil public_invocation.stdin_data, provider
      else
        assert_equal hive_invocation.stdin_data,
                     public_invocation.stdin_data,
                     provider
      end
      assert_equal hive_invocation.provider, public_invocation.provider, provider
      assert_equal hive_invocation.launcher_identity,
                   public_invocation.launcher_identity,
                   provider
    end
  end

  def test_builtin_usage_variants_match_hive_boundary
    events = {
      claude: [
        {
          "type" => "result",
          "usage" => {
            "input_tokens" => 3,
            "output_tokens" => 2,
            "cache_read_input_tokens" => 1
          },
          "model" => "claude-sonnet"
        },
        {
          "type" => "stream_event",
          "event" => {
            "message" => {
              "usage" => { "inputTokens" => 6, "outputTokens" => 4 },
              "model" => "claude-opus"
            }
          }
        },
        { "type" => "result" }
      ],
      codex: [
        {
          "type" => "turn.completed",
          "usage" => { "input_tokens" => 4, "output_tokens" => 3 }
        },
        {
          "response" => {
            "usage" => {
              "prompt_tokens" => 8,
              "completion_tokens" => 5,
              "prompt_tokens_details" => { "cached_tokens" => 2 }
            },
            "model" => "gpt-5.6-terra"
          }
        },
        { "type" => "turn.completed" }
      ],
      pi: [
        {
          "type" => "result",
          "usage" => { "promptTokens" => 5, "completionTokens" => 4 }
        },
        {
          "info" => {
            "total_token_usage" => {
              "inputTokens" => 9,
              "outputTokens" => 6,
              "cachedTokens" => 3
            }
          },
          "modelUsage" => { "provider/model" => {} }
        },
        { "type" => "result" }
      ],
      grok: [
        {
          "type" => "end",
          "token_usage" => { "input_tokens" => 7, "output_tokens" => 2 }
        },
        { "type" => "end" }
      ]
    }

    events.each do |provider, variants|
      variants.each do |event|
        expected = Hive::AgentRuntime.extract_usage(
          Hive::AgentProfiles.lookup(provider),
          event
        )
        actual = AgentCliRuntime.extract_usage(provider, event)
        expected.nil? ? assert_nil(actual, provider) :
          assert_equal(expected, actual, provider)
      end
    end
  end

  def test_observation_normalization_and_redaction_match_hive_boundary
    raw = {
      exit_code: 1,
      timed_out: true,
      status: "error",
      usage: {
        input: "12",
        output: -4,
        cached: nil,
        model: "provider/model"
      },
      final_message: "stopped",
      error_message: "api_key=abcdefghijklmnopqrstuvwxyz"
    }

    %i[claude codex pi grok].each do |provider|
      expected = Hive::AgentRuntime.observe(
        Hive::AgentProfiles.lookup(provider),
        raw
      )
      actual = AgentCliRuntime.observe(provider, raw)

      assert_equal expected.to_h, actual.to_h, provider
      assert_includes(
        actual.diagnostic,
        "[REDACTED:generic_api_key]",
        provider
      )
    end
  end

  def test_local_builtin_probe_outcomes_match_hive_boundary
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".pi", "agent"))
      File.write(
        File.join(home, ".pi", "agent", "auth.json"),
        '{"provider":"configured"}'
      )
      overrides = {
        "HOME" => home,
        "ANTHROPIC_API_KEY" => "configured",
        "OPENAI_API_KEY" => "configured",
        "XAI_API_KEY" => "configured"
      }
      {
        claude: "HIVE_CLAUDE_BIN",
        codex: "HIVE_CODEX_BIN",
        pi: "HIVE_PI_BIN",
        grok: "HIVE_GROK_BIN"
      }.each do |provider, env_key|
        binary = File.join(home, "#{provider}-fixture")
        File.write(binary, <<~SH)
          #!/bin/sh
          printf '%s\n' '#{provider} 99.0.0'
        SH
        FileUtils.chmod(0o755, binary)
        overrides[env_key] = binary
      end

      Hive::AgentProfile.reset_version_cache!
      with_env(overrides) do
        %i[claude codex pi grok].each do |provider|
          public_result =
            AgentCliRuntime.probe(provider, home:, env: ENV.to_h)
          hive_result =
            Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(provider))

          assert public_result.ready, public_result.diagnostic
          assert_equal hive_result.version, public_result.version, provider
          assert_equal hive_result.provider, public_result.provider, provider
          assert_equal(
            hive_result.launcher_identity,
            AgentCliRuntime::Profiles.fetch(provider).launcher_identity,
            provider
          )
        end
      end
    end
  ensure
    Hive::AgentProfile.reset_version_cache!
  end

  def test_named_capability_evidence_matches_hive_boundary
    with_tmp_dir do |dir|
      binary = File.join(dir, "capable-agent")
      File.write(binary, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "capable-agent 1.2.3"
        elif [ "$1" = "--safe-mode" ] && [ "$2" = "--help" ]; then
          echo "Usage: capable-agent --safe-mode"
        else
          exit 1
        fi
      SH
      FileUtils.chmod(0o755, binary)
      public_profile = AgentCliRuntime::Profile.new(
        name: :fixture,
        bin_default: binary,
        headless_flag: "-p",
        version_flag: "--version",
        min_version: "1.0.0",
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )
      hive_profile = Hive::AgentProfile.new(
        name: :fixture,
        bin_default: binary,
        headless_flag: "-p",
        version_flag: "--version",
        min_version: "1.0.0",
        skill_syntax_format: "/%{skill}",
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      expected =
        Hive::AgentRuntime.require_capability!(hive_profile, :safe_mode)
      actual =
        AgentCliRuntime.require_capability!(public_profile, :safe_mode)
      public_probe = AgentCliRuntime.probe(public_profile)
      probe_evidence = public_probe.capability_evidence.find do |evidence|
        evidence.capability == :safe_mode
      end

      assert_equal expected.capability, actual.capability
      assert_equal expected.supported, actual.supported
      assert_equal expected.provider, actual.provider
      assert_equal expected.arguments, actual.arguments
      assert probe_evidence.supported
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
