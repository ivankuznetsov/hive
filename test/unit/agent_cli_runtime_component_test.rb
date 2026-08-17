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
      abort "wrong version" unless AgentCliRuntime::VERSION == "0.2.1"
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
    assert_equal "claude,codex,pi,grok,opencode\n", out
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

  def test_builtin_credential_environment_inventory_matches_hive_boundary
    %i[claude codex pi grok].each do |provider|
      assert_equal(
        Hive::AgentProfiles.lookup(provider).credential_environment_keys,
        AgentCliRuntime::Profiles.fetch(provider).credential_environment_keys,
        provider
      )
    end
  end

  def test_builtin_configuration_directory_inventory_matches_hive_boundary
    %i[claude codex pi grok].each do |provider|
      hive = Hive::AgentProfiles.lookup(provider)
      public_profile = AgentCliRuntime::Profiles.fetch(provider)
      assert_equal hive.configuration_environment_key,
                   public_profile.configuration_environment_key,
                   provider
      assert_equal hive.default_configuration_directory,
                   public_profile.default_configuration_directory,
                   provider
      assert_equal hive.configuration_directory(home: "/runtime", environment: {}),
                   public_profile.configuration_directory(home: "/runtime", env: {}),
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
      credential_paths = %w[
        .claude/.credentials.json
        .codex/auth.json
        .pi/agent/auth.json
        .grok/auth.json
      ]
      credential_paths.each do |relative_path|
        path = File.join(home, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, '{"provider":"configured"}')
      end
      overrides = { "HOME" => home }
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

  def test_hive_dependency_requires_the_published_opencode_line
    spec = Gem::Specification.load(File.expand_path("../../hive.gemspec", __dir__))
    dependency = spec.runtime_dependencies.find do |candidate|
      candidate.name == "agent-cli-runtime"
    end

    refute_nil dependency
    refute dependency.requirement.satisfied_by?(Gem::Version.new("0.1.1"))
    assert dependency.requirement.satisfied_by?(Gem::Version.new("0.2.0"))
    assert dependency.requirement.satisfied_by?(Gem::Version.new("0.2.99"))
    refute dependency.requirement.satisfied_by?(Gem::Version.new("0.3.0"))
    assert File.read(File.expand_path("../../lib/hive.rb", __dir__))
               .include?('require "agent_cli_runtime"')
    %i[claude codex pi grok opencode].each do |provider|
      assert_same AgentCliRuntime::Profiles.fetch(provider),
                  Hive::AgentProfiles.lookup(provider).runtime_profile
    end
  end

  def test_opencode_typed_result_abi_and_normalization_match_hive_boundary
    {
      Route: AgentCliRuntime::Route,
      OpenCodePreparationRequest: AgentCliRuntime::OpenCodePreparationRequest,
      PreparedInvocation: AgentCliRuntime::PreparedInvocation,
      TerminationEvidence: AgentCliRuntime::TerminationEvidence,
      CapturedResult: AgentCliRuntime::CapturedResult,
      ParsedRun: AgentCliRuntime::ParsedRun,
      NormalizedUsage: AgentCliRuntime::NormalizedUsage,
      RouteIdentity: AgentCliRuntime::RouteIdentity,
      InspectionCommand: AgentCliRuntime::InspectionCommand,
      NormalizedOutcome: AgentCliRuntime::NormalizedOutcome
    }.each do |hive_name, component_value|
      assert_same component_value,
                  Hive::AgentRuntime.const_get(hive_name), hive_name
    end

    fixture_root = File.join(
      COMPONENT_ROOT, "test", "fixtures", "opencode", "v1.18.16"
    )
    stdout = File.read(File.join(fixture_root, "run-one-step.jsonl"))
    export = File.read(File.join(
      fixture_root, "session-export-matching.json"
    ))
    termination = AgentCliRuntime::TerminationEvidence.new(exit_code: 0)
    captured = AgentCliRuntime::CapturedResult.new(
      stdout:, stderr: "", termination:, inspection_output: export
    )

    public_parsed = AgentCliRuntime.parse_run(:opencode, stdout:)
    hive_parsed = Hive::AgentRuntime.parse_run(:opencode, stdout:)
    assert_equal public_parsed.to_h, hive_parsed.to_h
    public_outcome = AgentCliRuntime.normalize(
      :opencode, captured, requested_route: "anthropic/claude-sonnet-4-5"
    )
    hive_outcome = Hive::AgentRuntime.normalize(
      :opencode, captured, requested_route: "anthropic/claude-sonnet-4-5"
    )
    assert_equal public_outcome.to_h, hive_outcome.to_h
  end
end
