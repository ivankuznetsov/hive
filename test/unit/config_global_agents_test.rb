require "test_helper"
require "hive/config"

class ConfigGlobalAgentsTest < Minitest::Test
  include HiveTestHelper

  def test_registered_agent_names_projects_registry_symbols_to_strings
    # Locks the symbol→string projection that BackendPrompt depends on.
    names = Hive::Config.registered_agent_names

    assert_equal %w[claude codex grok pi], names.sort
    assert(names.all?(String), "registered_agent_names must be strings, not symbols")
  end

  def test_global_agent_backends_matches_registry
    # BackendPrompt filters the live registry through this canonical order.
    assert_equal Hive::AgentProfiles.registered_names.map(&:to_s).sort,
                 Hive::Config::GLOBAL_AGENT_BACKENDS.sort,
                 "GLOBAL_AGENT_BACKENDS and the AgentProfiles registry have drifted"
  end
end
