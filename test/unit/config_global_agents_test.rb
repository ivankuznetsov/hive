require "test_helper"
require "hive/config"

class ConfigGlobalAgentsTest < Minitest::Test
  include HiveTestHelper

  def test_registered_agent_names_projects_registry_symbols_to_strings
    # Locks the symbol→string projection that Init::Prompts depends on.
    names = Hive::Config.registered_agent_names

    assert_equal %w[claude codex grok pi], names.sort
    assert(names.all?(String), "registered_agent_names must be strings, not symbols")
  end
end
