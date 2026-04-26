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

  # --- agents.* config overrides --------------------------------------

  def test_lookup_with_cfg_applies_bin_override
    cfg = { "agents" => { "claude" => { "bin" => "/opt/custom/claude" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    refute_same Hive::AgentProfiles.lookup(:claude), profile
    assert_equal "/opt/custom/claude", profile.bin_default
    # Registry-stored profile must NOT be mutated.
    assert_equal "claude", Hive::AgentProfiles.lookup(:claude).bin_default
  end

  def test_lookup_with_cfg_applies_min_version_override
    cfg = { "agents" => { "claude" => { "min_version" => "99.99.99" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    assert_equal "99.99.99", profile.min_version
  end

  def test_lookup_with_cfg_returns_registered_profile_when_no_override
    cfg = { "agents" => { "codex" => { "bin" => "/opt/codex" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    assert_same Hive::AgentProfiles.lookup(:claude), profile
  end

  def test_lookup_with_cfg_returns_registered_profile_when_cfg_nil
    profile = Hive::AgentProfiles.lookup(:claude, cfg: nil)
    assert_same Hive::AgentProfiles.lookup(:claude), profile
  end

  def test_lookup_with_cfg_raises_config_error_on_unknown_override_key
    cfg = { "agents" => { "claude" => { "min_versn" => "1.2.3" } } }
    err = assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    end
    assert_match(/min_versn/, err.message)
    assert_match(/agents\.claude/, err.message)
  end

  def test_lookup_with_cfg_accepts_string_or_symbol_name_for_overrides
    cfg = { "agents" => { "codex" => { "bin" => "/opt/codex" } } }
    by_sym = Hive::AgentProfiles.lookup(:codex, cfg: cfg)
    by_str = Hive::AgentProfiles.lookup("codex", cfg: cfg)
    assert_equal "/opt/codex", by_sym.bin_default
    assert_equal "/opt/codex", by_str.bin_default
  end
end
