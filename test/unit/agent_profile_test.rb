require "test_helper"
require "hive/agent_profile"

class AgentProfileTest < Minitest::Test
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

  def test_freezes_at_construction
    profile = make_profile
    assert profile.frozen?
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

  def test_preflight_default_is_noop
    profile = make_profile
    assert_nil profile.preflight!
  end
end
