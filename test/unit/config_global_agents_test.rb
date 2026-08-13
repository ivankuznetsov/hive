require "test_helper"
require "hive/config"

class ConfigGlobalAgentsTest < Minitest::Test
  include HiveTestHelper

  def test_default_global_agents_filters_out_unregistered_backends
    with_restricted_registry(%i[claude]) do
      assert_equal %w[claude], Hive::Config.default_global_agents
    end
  end

  def test_default_global_agents_raises_when_no_default_backend_registered
    # When neither claude nor codex is registered (only the opt-in pi),
    # there is no default to fall back to and the method raises rather
    # than returning []. Exercises the `raise ConfigError` branch.
    with_restricted_registry(%i[pi]) do
      err = assert_raises(Hive::ConfigError) { Hive::Config.default_global_agents }
      assert_match(/no default agent backend is registered/, err.message)
    end
  end

  def test_registered_agent_names_projects_registry_symbols_to_strings
    # Locks the symbol→string projection that BackendPrompt depends on.
    names = Hive::Config.registered_agent_names

    assert_equal %w[claude codex grok pi], names.sort
    assert(names.all?(String), "registered_agent_names must be strings, not symbols")
  end

  def test_default_global_agents_returns_frozen_array
    assert Hive::Config.default_global_agents.frozen?,
           "default_global_agents must return a frozen array"
  end

  def test_global_agent_backends_matches_registry
    # Drift guard mirroring the load-time CHOICES/MODES assertion in
    # init/prompts.rb: GLOBAL_AGENT_BACKENDS (strings) and the AgentProfiles
    # registry (symbols) are two sources of truth for "known backends".
    # Registering a 4th profile without listing it here would silently make
    # it unselectable; this fails when the two sets diverge.
    assert_equal Hive::AgentProfiles.registered_names.map(&:to_s).sort,
                 Hive::Config::GLOBAL_AGENT_BACKENDS.sort,
                 "GLOBAL_AGENT_BACKENDS and the AgentProfiles registry have drifted"
  end

  private

  # Run the block with only `names` registered in the AgentProfiles
  # registry, restoring the full registry afterward. Lets a test exercise
  # the registered-intersection filter in default_global_agents, which is a
  # no-op while every built-in is auto-registered.
  def with_restricted_registry(names)
    originals = Hive::AgentProfiles.registered_names.to_h do |name|
      [ name, Hive::AgentProfiles.lookup(name) ]
    end
    Hive::AgentProfiles.reset_for_tests!
    names.each { |name| Hive::AgentProfiles.register(name, originals.fetch(name)) }
    yield
  ensure
    Hive::AgentProfiles.reset_for_tests!
    originals&.each { |name, profile| Hive::AgentProfiles.register(name, profile) }
  end
end
