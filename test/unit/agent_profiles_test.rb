require "test_helper"
require "hive/agent_profiles"

class AgentProfilesTest < Minitest::Test
  include HiveTestHelper

  def teardown
    # Restore the v1 built-in registrations after any test that mutated the
    # registry. require'd files don't re-evaluate, so reset + explicit
    # re-register is the deterministic path.
    Hive::AgentProfiles.reset_for_tests!
    Hive::AgentProfiles.register(:claude, Hive::AgentProfiles::CLAUDE)
    Hive::AgentProfiles.register(:codex, Hive::AgentProfiles::CODEX)
    Hive::AgentProfiles.register(:pi, Hive::AgentProfiles::PI)
  end

  def test_lookup_returns_v1_built_in_profiles
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:claude)
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:codex)
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:pi)
  end

  def test_lookup_accepts_string_or_symbol
    by_sym = Hive::AgentProfiles.lookup(:claude)
    by_str = Hive::AgentProfiles.lookup("claude")
    assert_same by_sym, by_str
  end

  def test_lookup_raises_unknown_agent_for_missing_name
    err = assert_raises(Hive::AgentProfiles::UnknownAgent) do
      Hive::AgentProfiles.lookup(:nonexistent)
    end
    assert_match(/unknown agent profile/, err.message)
  end

  def test_unknown_agent_inherits_config_error_for_exit_code
    assert_kind_of Hive::ConfigError,
                   Hive::AgentProfiles::UnknownAgent.new("test")
  end

  def test_register_replaces_existing_entry
    custom = Hive::AgentProfile.new(
      name: :custom,
      bin_default: "x",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )
    Hive::AgentProfiles.register(:claude, custom)
    assert_same custom, Hive::AgentProfiles.lookup(:claude)
  end

  def test_register_rejects_non_agent_profile
    err = assert_raises(ArgumentError) do
      Hive::AgentProfiles.register(:bad, "not a profile")
    end
    assert_match(/expected Hive::AgentProfile/, err.message)
  end

  def test_registered_names_lists_v1_built_ins
    names = Hive::AgentProfiles.registered_names.sort
    assert_includes names, :claude
    assert_includes names, :codex
    assert_includes names, :pi
  end

  def test_registered_check
    assert Hive::AgentProfiles.registered?(:claude)
    refute Hive::AgentProfiles.registered?(:nonexistent)
  end
end
