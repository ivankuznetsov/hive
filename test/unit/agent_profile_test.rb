require "test_helper"
require "hive/agent_profile"
require "hive/agent_support/opencode"
require "hive/implementation_identity"
require "hive/model_routing"

class AgentProfileTest < Minitest::Test
  def test_policy_capabilities_are_optional_and_frozen
    profile = make_profile
    assert_equal [], profile.policy_capabilities

    capable = make_profile(policy_capabilities: %i[tools settings_isolation])
    assert_equal %i[tools settings_isolation], capable.policy_capabilities
    assert_predicate capable.policy_capabilities, :frozen?
  end

  def test_billing_semantics_distinguish_subscription_guards_from_api_charges
    assert_equal :unknown, make_profile.billing_semantics
    assert_equal :subscription_backed,
                 make_profile(billing_semantics: :subscription_backed).billing_semantics
    assert_equal :api_billed, make_profile(billing_semantics: :api_billed).billing_semantics

    error = assert_raises(ArgumentError) do
      make_profile(billing_semantics: :guess)
    end
    assert_includes error.message, "billing_semantics"
  end

  def test_runtime_adapter_fields_are_optional_validated_and_frozen
    profile = make_profile
    assert_equal({}, profile.tool_scope_flags)
    refute profile.raw_cli_arguments_supported?
    assert_nil profile.structured_output_protocol

    capable = make_profile(
      tool_scope_flags: { allowed: "--allow", disallowed: "--deny" },
      raw_cli_arguments_supported: true,
      structured_output_protocol: :grok_end
    )
    assert_equal({ allowed: "--allow", disallowed: "--deny" }, capable.tool_scope_flags)
    assert_predicate capable.tool_scope_flags, :frozen?
    assert capable.raw_cli_arguments_supported?
    assert_equal :grok_end, capable.structured_output_protocol

    assert_raises(ArgumentError) { make_profile(tool_scope_flags: []) }
    assert_raises(ArgumentError) { make_profile(tool_scope_flags: { unknown: "--flag" }) }
    assert_raises(ArgumentError) { make_profile(tool_scope_flags: { allowed: "" }) }
    assert_raises(ArgumentError) { make_profile(structured_output_protocol: :unknown) }
  end

  def test_credential_environment_keys_are_optional_validated_and_frozen
    assert_empty make_profile.credential_environment_keys

    profile = make_profile(credential_environment_keys: %w[CUSTOM_TOKEN])
    assert_equal %w[CUSTOM_TOKEN], profile.credential_environment_keys
    assert_predicate profile.credential_environment_keys, :frozen?
    assert_equal({ "CUSTOM_TOKEN" => nil }, profile.subscription_environment)
    assert_equal({ "CUSTOM_TOKEN" => "" },
                 profile.subscription_environment(unset_value: ""))
    assert_predicate profile.subscription_environment, :frozen?

    session_path = make_profile(
      credential_environment_keys: %w[CUSTOM_API_KEY CUSTOM_AUTH_PATH]
    )
    assert_equal({ "CUSTOM_API_KEY" => nil },
                 session_path.subscription_environment)

    assert_raises(ArgumentError) do
      make_profile(credential_environment_keys: [ "not-valid" ])
    end
    assert_raises(ArgumentError) do
      make_profile(credential_environment_keys: %w[CUSTOM_TOKEN CUSTOM_TOKEN])
    end
  end

  def test_opencode_secret_placeholders_use_the_runtime_grammar
    profile = make_profile(
      name: :opencode,
      support_configuration: opencode_configuration(configuration: {
        "provider" => {
          "anthropic" => { "options" => { "apiKey" => "{env:ANTHROPIC_API_KEY}" } }
        }
      })
    )
    assert_equal "{env:ANTHROPIC_API_KEY}",
                 profile.support_configuration.configuration
                   .dig("provider", "anthropic", "options", "apiKey")

    assert_raises(ArgumentError) do
      make_profile(
        name: :opencode,
        support_configuration: opencode_configuration(configuration: {
          "provider" => { "anthropic" => { "options" => { "apiKey" => "${ANTHROPIC_API_KEY}" } } }
        })
      )
    end
  end

  def test_legacy_opencode_keywords_build_typed_support_configuration
    profile = make_profile(
      name: :opencode,
      opencode_configuration: { "model" => "openai/gpt-5" },
      opencode_credential_environment_keys: %w[OPENAI_API_KEY],
      opencode_plugins: %w[compound-engineering]
    )

    assert_instance_of Hive::AgentSupport::OpenCode::Configuration,
                       profile.support_configuration
    assert_nil profile.opencode_configuration_path
    assert_equal({ "model" => "openai/gpt-5" }, profile.opencode_configuration)
    assert_equal %w[OPENAI_API_KEY], profile.opencode_credential_environment_keys
    assert_equal %w[compound-engineering], profile.opencode_plugins

    path_profile = make_profile(
      name: :opencode,
      opencode_configuration_path: "/tmp/opencode.json"
    )
    assert_equal "/tmp/opencode.json", path_profile.opencode_configuration_path
    assert_nil path_profile.opencode_configuration
  end

  def test_rejects_mixed_legacy_and_typed_opencode_configuration
    error = assert_raises(ArgumentError) do
      make_profile(
        name: :opencode,
        support_configuration: opencode_configuration,
        opencode_plugins: %w[compound-engineering]
      )
    end

    assert_match(/legacy OpenCode keywords.*support_configuration/, error.message)
  end

  def test_claude_permission_presets_keep_legacy_default
    assert_equal %w[read-only scoped], make_profile(name: :claude).permission_presets
    assert_empty make_profile(name: :claude, permission_presets: []).permission_presets
  end

  def test_opencode_contract_fields_fail_closed_and_deep_freeze_json_values
    assert_raises(ArgumentError) do
      make_profile(name: :opencode, permission_presets: [ "unconfined" ])
    end
    assert_raises(ArgumentError) do
      opencode_configuration(plugins: "compound-engineering")
    end
    assert_raises(ArgumentError) do
      opencode_configuration(plugins: [ "" ])
    end
    assert_raises(ArgumentError) do
      opencode_configuration(plugins: %w[plugin plugin])
    end
    assert_raises(ArgumentError) do
      opencode_configuration(
        credential_environment_keys: %w[OPENAI_API_KEY OPENAI_API_KEY]
      )
    end
    assert_raises(ArgumentError) do
      opencode_configuration(configuration: [])
    end
    assert_raises(ArgumentError) do
      opencode_configuration(configuration: { "temperature" => Float::NAN })
    end
    assert_raises(ArgumentError) do
      opencode_configuration(configuration: {
          "providers" => [ { "api_key" => "literal-secret" } ]
        })
    end

    profile = make_profile(
      name: :opencode,
      support_configuration: opencode_configuration(configuration: {
        "providers" => [ { "name" => "anthropic" } ]
      })
    )
    providers = profile.support_configuration.configuration.fetch("providers")
    assert_predicate providers, :frozen?
    assert_predicate providers.first, :frozen?
    assert_predicate providers.first.fetch("name"), :frozen?

    error = assert_raises(Hive::ConfigError) do
      profile.with_overrides("isolation" => "best-effort")
    end
    assert_match(/is not a recognized override key/, error.message)

    error = assert_raises(Hive::ConfigError) do
      profile.with_overrides("credential_file" => "/tmp/opencode-auth.json")
    end
    assert_match(/is not a recognized override key/, error.message)
  end

  def test_configuration_directory_metadata_is_optional_and_validated
    profile = make_profile(
      configuration_environment_key: "CUSTOM_HOME",
      default_configuration_directory: ".custom"
    )
    assert_equal "/runtime/.custom",
                 profile.configuration_directory(home: "/runtime", environment: {})
    assert_equal "/configured", profile.configuration_directory(
      home: "/runtime", environment: { "CUSTOM_HOME" => "/configured" }
    )

    assert_raises(ArgumentError) do
      make_profile(configuration_environment_key: "bad-key")
    end
    assert_raises(ArgumentError) do
      make_profile(default_configuration_directory: "/absolute")
    end
  end

  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    Hive::AgentProfile.reset_version_cache!
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    ENV.delete("HIVE_FAKE_CLAUDE_VERSION")
    Hive::AgentProfile.reset_version_cache!
  end

  def make_profile(overrides = {})
    defaults = {
      name: :test,
      bin_default: "claude",
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    }
    Hive::AgentProfile.new(**defaults.merge(overrides))
  end

  def opencode_configuration(**options)
    Hive::AgentSupport::OpenCode::Configuration.new(**options)
  end

  def test_freezes_at_construction
    profile = make_profile
    assert profile.frozen?
  end

  def test_constructor_rejects_incomplete_and_untyped_runtime_profiles
    assert_raises(ArgumentError) { make_profile(bin_default: nil) }

    untyped_runtime = Struct.new(:name).new(:custom)
    error = assert_raises(ArgumentError) do
      Hive::AgentProfile.new(
        runtime_profile: untyped_runtime,
        skill_syntax_format: "/%{skill}"
      )
    end

    assert_match(/must be an AgentCliRuntime::Profile/, error.message)
  end

  def test_rejects_unknown_prompt_style
    error = assert_raises(ArgumentError) do
      make_profile(prompt_style: :shell_interpolation)
    end

    assert_includes error.message, "unknown prompt_style"
  end

  def test_initial_context_reserve_defaults_to_zero_and_must_be_non_negative
    assert_equal 0, make_profile.initial_context_tokens

    error = assert_raises(ArgumentError) do
      make_profile(initial_context_tokens: -1)
    end
    assert_includes error.message, "non-negative Integer"
  end

  def test_identity_arguments_translate_model_and_supported_effort_as_discrete_argv
    profile = make_profile(
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder: ->(effort) { [ "-c", "reasoning_effort=#{effort}" ] }
    )

    result = profile.identity_arguments(model: "gpt-5.6-terra", effort: "medium")

    assert_equal [ "--model", "gpt-5.6-terra", "-c", "reasoning_effort=medium" ],
                 result.native_arguments
    assert_equal "medium", result.requested_effort
    assert_equal "medium", result.effective_effort
    assert result.effort_supported
  end

  def test_identity_arguments_preserve_default_effort_without_rendering_a_flag
    profile = Hive::AgentProfiles.lookup(:grok)

    result = profile.identity_arguments(model: "grok-4.6", effort: "default")

    assert_equal [ "--model", "grok-4.6" ], result.native_arguments
    assert_equal "default", result.requested_effort
    assert_nil result.effective_effort
    assert result.effort_supported
  end

  def test_identity_arguments_report_unsupported_effort_without_native_argument
    profile = make_profile(model_argument_builder: ->(model) { [ "--model", model ] })

    result = profile.identity_arguments(model: "provider/model-v1", effort: "high")

    assert_equal [ "--model", "provider/model-v1" ], result.native_arguments
    assert_equal "high", result.requested_effort
    assert_nil result.effective_effort
    refute result.effort_supported
  end

  def test_identity_arguments_can_record_a_concrete_default_without_pinning_it
    profile = make_profile(model_argument_builder: ->(model) { [ "--model", model ] })

    result = profile.identity_arguments(model: "provider/default-v2", effort: nil, pin_model: false)

    assert_equal [], result.native_arguments
    assert_equal "provider/default-v2", result.model
    refute result.model_pinned
  end

  def test_identity_arguments_reject_shell_shaped_model_and_invalid_effort
    profile = make_profile(
      model_argument_builder: ->(model) { [ "--model", model ] },
      effort_argument_builder: ->(effort) { [ "--effort", effort ] }
    )

    assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
      profile.identity_arguments(model: "safe\n--dangerous", effort: "high")
    end
    assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
      profile.identity_arguments(model: "safe", effort: "high; touch /tmp/x")
    end
  end

  def test_concrete_default_model_uses_profile_resolver_and_rejects_default_sentinel
    resolved = make_profile(default_model_resolver: ->(**) { "vendor/model-1" })
    assert_equal "vendor/model-1", resolved.concrete_default_model

    unresolved = make_profile(default_model_resolver: ->(**) { "default" })
    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      unresolved.concrete_default_model
    end
    assert_match(/concrete default model/, error.message)
  end

  def test_concrete_default_model_requires_and_wraps_profile_resolver_failures
    missing = make_profile
    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      missing.concrete_default_model
    end
    assert_match(/cannot resolve a concrete default model/, error.message)

    broken = make_profile(default_model_resolver: ->(**) { raise IOError, "settings unavailable" })
    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      broken.concrete_default_model
    end
    assert_match(/default-model resolution failed: settings unavailable/, error.message)
  end

  def test_identity_arguments_requires_model_pin_support
    profile = make_profile

    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      profile.identity_arguments(model: "provider/model-v1", effort: nil)
    end

    assert_match(/cannot pin model/, error.message)
  end

  def test_identity_arguments_preserve_other_package_capability_diagnostics
    runtime = AgentCliRuntime::Profile.new(
      name: :custom,
      bin_default: "custom-agent",
      headless_flag: "-p",
      version_flag: "--version",
      model_argument_builder: lambda do |_model|
        raise AgentCliRuntime::UnsupportedCapability, "synthetic package refusal"
      end
    )
    profile = Hive::AgentProfile.new(
      runtime_profile: runtime,
      skill_syntax_format: "/%{skill}"
    )

    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      profile.identity_arguments(model: "provider/model", effort: nil)
    end

    assert_equal "synthetic package refusal", error.message
  end

  def test_routed_effort_rejects_profiles_without_native_effort_support
    %i[pi].each do |name|
      profile = Hive::AgentProfiles.lookup(name)
      resolution = Hive::ModelRouting.resolve(
        models: { "plan" => { "effort" => "high" } },
        stage: "plan",
        provider: name,
        current: { model: "provider/model-v1" }
      )

      error = assert_raises(Hive::ConfigError) do
        profile.routing_arguments(resolution)
      end

      assert_match(/models\.plan\.effort/, error.message)
      assert_match(/profile :#{name}/, error.message)
      assert_match(/does not support reasoning effort/, error.message)
    end
  end

  def test_builtin_profiles_render_only_their_native_routed_arguments
    cases = {
      claude: {
        model: "opus",
        effort: "high",
        global: [],
        subcommand: [ "--model", "opus", "--effort", "high" ]
      },
      codex: {
        model: "gpt-5.6-sol",
        effort: "xhigh",
        global: [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh" ],
        subcommand: []
      },
      grok: {
        model: "grok-code-fast-1",
        effort: "high",
        global: [],
        subcommand: [
          "--model", "grok-code-fast-1",
          "--reasoning-effort", "high"
        ]
      },
      pi: {
        model: "openai/gpt-5.6-sol",
        effort: nil,
        global: [],
        subcommand: [ "--model", "openai/gpt-5.6-sol" ]
      },
      opencode: {
        model: "anthropic/claude-sonnet-4-5",
        effort: "high",
        global: [],
        subcommand: [
          "--model", "anthropic/claude-sonnet-4-5", "--variant", "high"
        ]
      }
    }

    cases.each do |name, expected|
      profile = Hive::AgentProfiles.lookup(name)
      resolution = Hive::ModelRouting.resolve(
        models: {
          "plan" => {
            "model" => expected.fetch(:model),
            **({ "effort" => expected.fetch(:effort) } if expected.fetch(:effort))
          }
        },
        stage: "plan",
        provider: name
      )

      arguments = profile.routing_arguments(resolution)

      assert_equal expected.fetch(:global), arguments.global_arguments, name
      assert_equal expected.fetch(:subcommand), arguments.subcommand_arguments, name
      assert_equal name, arguments.profile_name
      assert_equal "plan", arguments.stage
    end

    assert_equal(
      %w[default inherit none minimal low medium high xhigh max],
      Hive::AgentProfiles.lookup(:grok).routed_effort_values
    )
    assert_equal %w[minimal low medium high xhigh max],
                 Hive::AgentProfiles.lookup(:opencode).routed_effort_values
  end

  def test_opencode_routed_model_requires_an_exact_nested_route
    profile = Hive::AgentProfiles.lookup(:opencode)
    resolution = Hive::ModelRouting.resolve(
      models: { "plan" => { "model" => "claude-sonnet-4-5" } },
      stage: "plan",
      provider: :opencode
    )

    error = assert_raises(Hive::ConfigError) do
      profile.routing_arguments(resolution)
    end

    assert_match(/exact OpenCode provider\/model route/, error.message)
  end

  def test_codex_routed_model_and_effort_can_be_rendered_independently
    profile = Hive::AgentProfiles.lookup(:codex)
    only_model = profile.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "gpt-5.6-sol" } },
        stage: "plan",
        provider: :codex
      )
    )
    only_effort = profile.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "effort" => "xhigh" } },
        stage: "plan",
        provider: :codex
      )
    )

    assert_equal [ "--model", "gpt-5.6-sol" ], only_model.global_arguments
    assert_equal [ "-c", "model_reasoning_effort=xhigh" ], only_effort.global_arguments
  end

  def test_routing_resolution_cannot_be_rendered_by_a_different_provider_profile
    resolution = Hive::ModelRouting.resolve(
      models: { "plan" => { "model" => "gpt-5.6-sol" } },
      stage: "plan",
      provider: :codex
    )

    error = assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles.lookup(:claude).routing_arguments(resolution)
    end

    assert_match(/selected provider :codex/, error.message)
    assert_match(/profile :claude/, error.message)
    assert_match(/may not change providers/, error.message)
  end

  def test_routed_field_renders_fallback_field_with_profile_native_sentinels
    claude = Hive::AgentProfiles.lookup(:claude)
    inherited_model = claude.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "effort" => "high" } },
        stage: "plan",
        provider: :claude,
        current: { model: "inherit" }
      )
    )
    default_effort = claude.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "opus" } },
        stage: "plan",
        provider: :claude,
        current: { effort: "default" }
      )
    )

    assert_equal [ "--effort", "high" ], inherited_model.subcommand_arguments
    assert_equal [ "--model", "opus" ], default_effort.subcommand_arguments
  end

  def test_routed_effort_uses_each_profile_native_vocabulary
    codex = Hive::AgentProfiles.lookup(:codex)
    claude = Hive::AgentProfiles.lookup(:claude)

    codex_error = assert_raises(Hive::ConfigError) do
      codex.routing_arguments(
        Hive::ModelRouting.resolve(
          models: { "plan" => { "effort" => "max" } },
          stage: "plan",
          provider: :codex
        )
      )
    end
    claude_error = assert_raises(Hive::ConfigError) do
      claude.routing_arguments(
        Hive::ModelRouting.resolve(
          models: { "plan" => { "effort" => "minimal" } },
          stage: "plan",
          provider: :claude
        )
      )
    end

    assert_match(/must be one of/, codex_error.message)
    assert_match(/must be one of/, claude_error.message)
  end

  def test_inactive_routing_does_not_create_a_staged_argument_channel
    profile = Hive::AgentProfiles.lookup(:codex)
    resolution = Hive::ModelRouting.resolve(
      models: {},
      stage: nil,
      provider: :codex,
      current: { model: " untouched ", effort: "legacy-shape" }
    )

    assert_nil profile.routing_arguments(resolution)
  end

  def test_custom_profile_routing_metadata_is_optional_and_preserved_by_overrides
    legacy = make_profile(model_argument_builder: ->(model) { [ "--model", model ] })
    assert_equal :subcommand, legacy.routing_argument_placement

    global = make_profile(
      model_argument_builder: ->(model) { [ "--choose-model", model ] },
      routed_effort_values: %w[low high],
      routing_argument_placement: :global
    )
    overridden = global.with_overrides("min_version" => "9.9.9")

    assert_equal :global, overridden.routing_argument_placement
    assert_equal %w[low high], overridden.routed_effort_values

    error = assert_raises(ArgumentError) do
      make_profile(routing_argument_placement: :interleaved)
    end
    assert_match(/unknown routing_argument_placement/, error.message)
  end

  def test_routed_controls_reject_invalid_types_unsupported_fields_and_values
    profile = make_profile
    provenance = Hive::ModelRouting::Provenance.new(kind: :exact, key: "plan")

    assert_raises(ArgumentError) do
      profile.validate_routed_control!(Object.new)
    end

    unsupported_model = Hive::ModelRouting::EffectiveControl.new(
      stage: "plan",
      profile: :test,
      provider: :test,
      field: :model,
      value: "provider/model",
      provenance: provenance
    )
    error = assert_raises(Hive::ConfigError) do
      profile.validate_routed_control!(unsupported_model)
    end
    assert_match(/does not support model selection/, error.message)

    unknown_field = Hive::ModelRouting::EffectiveControl.new(
      stage: "plan",
      profile: :test,
      provider: :test,
      field: :temperature,
      value: "high",
      provenance: provenance
    )
    error = assert_raises(ArgumentError) do
      profile.validate_routed_control!(unknown_field)
    end
    assert_match(/unknown routed control field/, error.message)

    non_scalar = Hive::ModelRouting::EffectiveControl.new(
      stage: "plan",
      profile: :test,
      provider: :test,
      field: :model,
      value: 42,
      provenance: provenance
    )
    error = assert_raises(Hive::ConfigError) do
      profile.validate_routed_control!(non_scalar)
    end
    assert_match(/must be a non-blank scalar/, error.message)
  end

  def test_routing_argument_validation_rejects_untyped_cross_profile_and_tampered_values
    profile = Hive::AgentProfiles.lookup(:codex)
    arguments = profile.routing_arguments(
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "gpt-5.6-sol" } },
        stage: "plan",
        provider: :codex
      )
    )

    assert_raises(ArgumentError) { profile.routing_arguments(Object.new) }
    assert_raises(ArgumentError) { profile.validate_routing_arguments!(Object.new) }

    cross_profile = Hive::AgentProfile::RoutingArguments.new(
      **arguments.to_h.merge(profile_name: :claude)
    )
    error = assert_raises(ArgumentError) do
      profile.validate_routing_arguments!(cross_profile)
    end
    assert_match(/cannot be used with :codex/, error.message)

    tampered = Hive::AgentProfile::RoutingArguments.new(
      **arguments.to_h.merge(global_arguments: arguments.global_arguments + [ "--tampered" ])
    )
    error = assert_raises(ArgumentError) do
      profile.validate_routing_arguments!(tampered)
    end
    assert_match(/do not match agent profile :codex native rendering/, error.message)
  end

  def test_bin_uses_env_override_when_set
    profile = make_profile(bin_default: "/nonexistent/claude", env_bin_override_key: "HIVE_CLAUDE_BIN")
    assert_equal FAKE_BIN, profile.bin
  end

  def test_bin_falls_back_to_default_when_env_empty
    ENV["HIVE_CLAUDE_BIN"] = ""
    profile = make_profile(bin_default: "default-claude", env_bin_override_key: "HIVE_CLAUDE_BIN")
    assert_equal "default-claude", profile.bin
  end

  def test_bin_falls_back_to_default_when_no_override_key
    ENV.delete("HIVE_FAKE_NO_KEY")
    profile = make_profile(bin_default: "fallback", env_bin_override_key: nil)
    assert_equal "fallback", profile.bin
  end

  def test_check_version_passes_when_above_minimum
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "2.0.0"
    assert_equal "2.0.0", profile.check_version!
  end

  def test_check_version_passes_when_no_minimum_set
    profile = make_profile(min_version: nil)
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "0.0.1"
    assert_equal "0.0.1", profile.check_version!
  end

  def test_check_version_raises_when_below_minimum
    profile = make_profile(min_version: "5.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "1.0.0"
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/below minimum/, err.message)
  end

  def test_check_version_rejects_ambiguous_version_output
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] =
      "wrapper 9.9.9 delegates to claude 2.0.0"

    err = assert_raises(Hive::AgentError) { profile.check_version! }

    assert_match(/ambiguous/, err.message)
    assert_match(/9\.9\.9, 2\.0\.0/, err.message)
  end

  def test_check_version_rejects_output_without_a_version
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "version unavailable"

    err = assert_raises(Hive::AgentError) { profile.check_version! }

    assert_match(/could not parse/, err.message)
  end

  def test_check_version_raises_when_binary_not_runnable
    profile = make_profile(bin_default: "/this/does/not/exist", env_bin_override_key: nil)
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/not runnable/, err.message)
  end

  def test_check_version_raises_when_headless_unsupported
    profile = make_profile(headless_supported: false)
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/not headless-supported/, err.message)
  end

  def test_check_version_raises_when_version_check_times_out
    with_tmp_dir do |dir|
      binary = File.join(dir, "hung-version-cli")
      File.write(binary, <<~SH)
        #!/usr/bin/env bash
        trap '' TERM
        deadline=$((SECONDS + 2))
        while [ "$SECONDS" -lt "$deadline" ]; do :; done
      SH
      File.chmod(0o755, binary)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      with_version_check_timeout(0.1) do
        # Profiles now capture their typed version timeout at construction so
        # OpenCode can use a longer cold-start budget without slowing every
        # provider. Construct under the test override rather than mutating the
        # default after the profile has already copied it.
        profile = make_profile(
          bin_default: binary, env_bin_override_key: nil, min_version: "1.0.0"
        )
        err = assert_raises(Hive::AgentError) { profile.check_version! }
        assert_match(/version check timed out/, err.message)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_check_version_caches_result
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "2.0.0"
    first = profile.check_version!
    # Swap to a version below the floor; cached value should be returned
    # without re-running the binary, so no error is raised.
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "0.0.1"
    second = profile.check_version!
    assert_equal first, second
  end

  def test_invalid_status_detection_mode_raises_at_construction
    err = assert_raises(ArgumentError) do
      Hive::AgentProfile.new(
        name: :bad,
        bin_default: "x",
        headless_flag: "-p",
        version_flag: "--version",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :unknown_mode
      )
    end
    assert_match(/unknown status_detection_mode/, err.message)
  end

  def test_invalid_prompt_style_raises_at_construction
    err = assert_raises(ArgumentError) do
      make_profile(prompt_style: :unknown_style)
    end

    assert_match(/unknown prompt_style/, err.message)
  end

  def test_preflight_default_is_noop
    profile = make_profile
    assert_nil profile.preflight!
  end

  def test_usage_extractor_default_is_noop
    profile = make_profile
    assert_nil profile.extract_usage_event("not-json")
  end

  def test_workspace_write_mode_fails_closed_without_profile_capability
    profile = make_profile(permission_skip_flag: "--dangerous")

    error = assert_raises(ArgumentError) do
      profile.permission_flags(Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE)
    end

    assert_includes error.message, "cannot enforce workspace-write"
  end

  def test_workspace_write_mode_uses_frozen_profile_flags_without_bypass
    profile = make_profile(
      permission_skip_flag: "--dangerous",
      workspace_write_flags: [ "--sandbox", "workspace-write" ]
    )

    flags = profile.permission_flags(Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE)

    assert_equal [ "--sandbox", "workspace-write" ], flags
    refute_includes flags, "--dangerous"
    assert profile.workspace_write_supported?
  end

  def test_read_only_mode_uses_profile_flags_without_bypass
    profile = make_profile(
      read_only_flags: [ "--sandbox", "read-only", "-c", 'approval_policy="never"' ]
    )

    flags = profile.permission_flags(Hive::AgentProfile::READ_ONLY_PERMISSION_MODE)

    assert_equal [ "--sandbox", "read-only", "-c", 'approval_policy="never"' ], flags
    assert profile.read_only_supported?
    refute_includes flags, "--dangerously-skip-permissions"
  end

  def test_read_only_mode_fails_closed_without_profile_capability
    profile = make_profile(permission_skip_flag: "--dangerous")

    error = assert_raises(ArgumentError) do
      profile.permission_flags(Hive::AgentProfile::READ_ONLY_PERMISSION_MODE)
    end

    assert_includes error.message, "cannot enforce read-only"
  end

  def test_cli_capability_must_be_declared
    error = assert_raises(Hive::AgentError) do
      make_profile.require_cli_capability!(:safe_mode)
    end

    assert_includes error.message, "does not declare CLI capability"
  end

  def test_cli_capabilities_require_a_hash_and_non_empty_flags
    type_error = assert_raises(ArgumentError) { make_profile(cli_capabilities: [ "--safe-mode" ]) }
    empty_error = assert_raises(ArgumentError) { make_profile(cli_capabilities: { safe_mode: [] }) }

    assert_includes type_error.message, "must be a Hash"
    assert_includes empty_error.message, "must declare at least one flag"
  end

  def test_cli_capability_help_failure_is_explicit
    with_tmp_dir do |dir|
      binary = capability_binary(dir, help: "", help_exit: 2)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      error = assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }

      assert_includes error.message, "capability check failed"
    end
  end

  def test_cli_capability_verifies_options_without_treating_values_as_flags
    with_tmp_dir do |dir|
      binary = File.join(dir, "valued-capability-cli")
      File.write(binary, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo "2.1.179 (Claude Code)"
          exit 0
        fi
        printf '%s\n' '--safe-mode --tools <tools...>'
      SH
      File.chmod(0o755, binary)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: {
          patrol: [ "--safe-mode", "--tools", "Read,Grep,Glob" ]
        }
      )

      assert_equal [ "--safe-mode", "--tools", "Read,Grep,Glob" ],
                   profile.require_cli_capability!(:patrol)
    end
  end

  def test_cli_capability_help_timeout_terminates_and_reaps_hung_process
    with_tmp_dir do |dir|
      pid_path = File.join(dir, "capability-help.pid")
      binary = File.join(dir, "hung-capability-cli")
      File.write(binary, <<~SH)
        #!/usr/bin/env bash
        if [ "${1:-}" = "--version" ]; then
          echo "2.1.179 (Claude Code)"
          exit 0
        fi
        if [ "${1:-}" = "--safe-mode" ] && [ "${2:-}" = "--help" ]; then
          printf '%s\n' "$$" > #{pid_path.inspect}
          trap '' TERM
          deadline=$((SECONDS + 2))
          while [ "$SECONDS" -lt "$deadline" ]; do :; done
        fi
      SH
      File.chmod(0o755, binary)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = with_version_check_timeout(0.1) do
        assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_includes error.message, "capability check could not run"
      assert_operator elapsed, :<, 1.0
      pid = Integer(File.read(pid_path), 10)
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_process_probe_implementation_is_not_duplicated_in_hive_profile
    refute_includes Hive::AgentProfile.private_instance_methods,
                    :bounded_capture3
    assert_includes AgentCliRuntime::Profile.private_instance_methods,
                    :bounded_capture3
  end

  def test_cli_capability_binary_disappearing_after_version_check_is_explicit
    with_tmp_dir do |dir|
      binary = capability_binary(dir, help: "--safe-mode")
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )
      profile.check_version!
      FileUtils.rm_f(binary)

      error = assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }

      assert_includes error.message, "capability check could not run"
    end
  end

  def test_with_overrides_preserves_cli_capabilities
    profile = make_profile(cli_capabilities: { safe_mode: [ "--safe-mode" ] })

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal({ safe_mode: [ "--safe-mode" ] }, overridden.cli_capabilities)
  end

  def test_with_overrides_preserves_initial_context_reserve
    profile = make_profile(initial_context_tokens: 12_345)

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal 12_345, overridden.initial_context_tokens
  end

  def test_with_overrides_preserves_identity_capabilities
    resolver = ->(**) { "model-v1" }
    model_builder = ->(model) { [ "--model", model ] }
    effort_builder = ->(effort) { [ "--effort", effort ] }
    profile = make_profile(
      default_model_resolver: resolver,
      model_argument_builder: model_builder,
      effort_argument_builder: effort_builder,
      launcher_identity: "custom-launcher/v2"
    )

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_same resolver, overridden.default_model_resolver
    assert_same model_builder, overridden.model_argument_builder
    assert_same effort_builder, overridden.effort_argument_builder
    assert_equal "custom-launcher/v2", overridden.launcher_identity
  end

  def test_with_overrides_preserves_runtime_adapter_fields
    profile = make_profile(
      tool_scope_flags: { allowed: "--allow" },
      raw_cli_arguments_supported: true
    )

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal({ allowed: "--allow" }, overridden.tool_scope_flags)
    assert overridden.raw_cli_arguments_supported?
  end

  # --- with_overrides ---------------------------------------------------

  def test_with_overrides_returns_self_for_nil_or_empty
    profile = make_profile
    assert_same profile, profile.with_overrides(nil)
    assert_same profile, profile.with_overrides({})
  end

  def test_with_overrides_replaces_bin_default
    profile = make_profile(bin_default: "claude")
    overridden = profile.with_overrides("bin" => "/opt/custom/claude")
    refute_same profile, overridden
    assert_equal "/opt/custom/claude", overridden.bin_default
    # Original profile is not mutated.
    assert_equal "claude", profile.bin_default
  end

  def test_with_overrides_replaces_min_version
    profile = make_profile(min_version: "1.0.0")
    overridden = profile.with_overrides("min_version" => "9.9.9")
    assert_equal "9.9.9", overridden.min_version
  end

  def test_with_overrides_replaces_env_override_key
    profile = make_profile(env_bin_override_key: "HIVE_CLAUDE_BIN")
    overridden = profile.with_overrides("env_override" => "MY_CUSTOM_BIN")
    assert_equal "MY_CUSTOM_BIN", overridden.env_bin_override_key
    assert_equal %w[MY_CUSTOM_BIN HIVE_CLAUDE_BIN],
                 overridden.runtime_profile.env_bin_override_keys
  end

  def test_with_overrides_preserves_prompt_style
    profile = make_profile(prompt_style: :headless_flag_value)

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal :headless_flag_value, overridden.prompt_style
  end

  def test_with_overrides_raises_for_non_hash
    profile = make_profile

    err = assert_raises(Hive::ConfigError) do
      profile.with_overrides("not-a-hash")
    end

    assert_match(/override must be a Hash/, err.message)
  end

  def test_with_overrides_raises_for_unknown_key
    profile = make_profile
    err = assert_raises(Hive::ConfigError) do
      profile.with_overrides("not_a_real_key" => "x")
    end
    assert_match(/not_a_real_key/, err.message)
  end

  def test_with_overrides_returns_frozen_profile
    profile = make_profile
    overridden = profile.with_overrides("bin" => "/x")
    assert overridden.frozen?
  end

  def test_runtime_override_inherits_binary_probe_and_checks_capabilities
    with_tmp_dir do |dir|
      binary = capability_binary(dir, help: "--safe-mode")
      profile = make_profile(
        bin_default: binary,
        env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      ).with_overrides("min_version" => "1.0.0")
      runtime = profile.runtime_profile

      assert runtime.binary_installed?(env: { "PATH" => "" })
      assert_equal "2.1.179", runtime.check_version!(env: {})
      assert_equal [ "--safe-mode" ], runtime.require_cli_capability!(:safe_mode)

      command = File.join(dir, "custom-agent")
      FileUtils.cp(binary, command)
      command_profile = profile.with_overrides("bin" => "custom-agent")
      assert command_profile.runtime_profile.binary_installed?(
        env: { "PATH" => dir }
      )

      malformed_environment = Object.new
      malformed_environment.define_singleton_method(:[]) { |_key| "set" }
      malformed_environment.define_singleton_method(:fetch) do |*_args|
        raise ArgumentError, "synthetic malformed environment"
      end
      overridden = profile.with_overrides("env_override" => "CUSTOM_BIN")
      refute overridden.runtime_profile.binary_installed?(
        env: malformed_environment
      )
    end
  end

  def test_usage_extractor_errors_are_ignored
    profile = make_profile(usage_extractor: ->(_event) { raise "bad usage payload" })

    assert_nil profile.extract_usage_event({ "type" => "result" })
  end

  # Provider error shape lives with the provider, so Hive's profile is a pure
  # pass-through here — the runtime profile decides what counts as a refusal.
  def test_error_extraction_delegates_to_the_runtime_profile
    runtime_class = Class.new(AgentCliRuntime::Profile) do
      def extract_error_event(event)
        event["errorMessage"]
      end
    end
    runtime = runtime_class.new(
      name: :custom,
      bin_default: "custom-agent",
      headless_flag: "-p",
      version_flag: "--version"
    )
    profile = Hive::AgentProfile.new(
      runtime_profile: runtime,
      skill_syntax_format: "/%{skill}"
    )

    assert_equal(
      "402: Prompt tokens limit exceeded",
      profile.extract_error_event(
        { "errorMessage" => "402: Prompt tokens limit exceeded" }
      )
    )
  end

  def test_runtime_adapter_contains_usage_extractor_failures
    runtime_class = Class.new(AgentCliRuntime::Profile) do
      def extract_usage_event(_event)
        raise "synthetic package usage failure"
      end
    end
    runtime = runtime_class.new(
      name: :custom,
      bin_default: "custom-agent",
      headless_flag: "-p",
      version_flag: "--version"
    )
    profile = Hive::AgentProfile.new(
      runtime_profile: runtime,
      skill_syntax_format: "/%{skill}"
    )

    assert_nil profile.extract_usage_event({ "type" => "result" })
  end

  def capability_binary(dir, help:, help_exit: 0)
    path = File.join(dir, "capable-cli")
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "${1:-}" = "--version" ]; then
        echo "2.1.179 (Claude Code)"
        exit 0
      fi
      if [ "${1:-}" = "--safe-mode" ] && [ "${2:-}" = "--help" ]; then
        printf '%s\\n' #{help.inspect}
        exit #{help_exit}
      fi
      exit 0
    SH
    File.chmod(0o755, path)
    path
  end

  def with_version_check_timeout(seconds)
    original = AgentCliRuntime::Profile::CAPTURE_TIMEOUT_SECONDS
    AgentCliRuntime::Profile.send(:remove_const, :CAPTURE_TIMEOUT_SECONDS)
    AgentCliRuntime::Profile.const_set(:CAPTURE_TIMEOUT_SECONDS, seconds)
    yield
  ensure
    AgentCliRuntime::Profile.send(:remove_const, :CAPTURE_TIMEOUT_SECONDS)
    AgentCliRuntime::Profile.const_set(:CAPTURE_TIMEOUT_SECONDS, original)
  end

  def test_verify_skill_reports_not_applicable_or_delegates
    assert_equal [ :not_applicable, "no skill verifier configured for this profile" ],
                 make_profile.verify_skill("/anything")

    calls = []
    verifier = lambda do |invocation, project_root:|
      calls << [ invocation, project_root ]
      [ :present, "/tmp/SKILL.md" ]
    end
    profile = make_profile(skill_verifier: verifier)

    assert_equal [ :present, "/tmp/SKILL.md" ], profile.verify_skill("/demo", project_root: "/repo")
    assert_equal [ [ "/demo", "/repo" ] ], calls
  end
end
