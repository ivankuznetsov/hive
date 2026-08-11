require "test_helper"
require "hive/agent_profiles/launch_bindings"

class AgentProfilesLaunchBindingsTest < Minitest::Test
  include HiveTestHelper

  def test_default_binding_preserves_existing_adapter_environment
    binding = Hive::AgentProfiles::LaunchBindings.resolve(
      adapter: "codex", binding_id: "default", environment: {}
    )

    assert binding.default?
    assert_empty binding.environment
    assert_nil binding.selector_name
  end

  def test_named_bindings_resolve_distinct_external_contexts_without_persisting_paths
    with_tmp_dir do |root|
      first = File.join(root, "first")
      second = File.join(root, "second")
      FileUtils.mkdir_p([ first, second ])
      environment = {
        "HIVE_PROVIDER_BINDING_CODEX_TEAM_A" => first,
        "HIVE_PROVIDER_BINDING_CODEX_TEAM_B" => second
      }

      a = Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "team-a", environment: environment
      )
      b = Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "team-b", environment: environment
      )

      refute_equal a.environment.fetch("CODEX_HOME"), b.environment.fetch("CODEX_HOME")
      assert_nil a.environment.fetch("OPENAI_API_KEY")
      refute_includes a.id, root
      refute_includes a.selector_name, root
    end
  end

  def test_missing_relative_and_unknown_bindings_fail_before_spawn
    assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "team", environment: {}
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "team",
        environment: { "HIVE_PROVIDER_BINDING_CODEX_TEAM" => "relative" }
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "unknown", binding_id: "default", environment: {}
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "Invalid!", environment: {}
      )
    end
  end

  def test_preflight_environment_is_restored
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "codex"))
      binding = Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "codex", binding_id: "team",
        environment: { "HIVE_PROVIDER_BINDING_CODEX_TEAM" => File.join(root, "codex") }
      )
      with_env("CODEX_HOME" => "/original", "OPENAI_API_KEY" => "secret") do
        Hive::AgentProfiles::LaunchBindings.with_preflight_environment(binding) do
          assert_equal File.join(root, "codex"), ENV.fetch("CODEX_HOME")
          refute ENV.key?("OPENAI_API_KEY")
        end
        assert_equal "/original", ENV.fetch("CODEX_HOME")
        assert_equal "secret", ENV.fetch("OPENAI_API_KEY")
      end
    end
  end

  def test_named_claude_binding_clears_both_ambient_api_key_aliases
    with_tmp_dir do |root|
      binding = Hive::AgentProfiles::LaunchBindings.resolve(
        adapter: "claude",
        binding_id: "team",
        environment: { "HIVE_PROVIDER_BINDING_CLAUDE_TEAM" => root }
      )

      assert_nil binding.environment.fetch("ANTHROPIC_API_KEY")
      assert_nil binding.environment.fetch("CLAUDE_API_KEY")
    end
  end
end
