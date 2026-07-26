require "test_helper"

class TestHelperIsolationTest < Minitest::Test
  USER_ENV_PATHS = {
    "HOME" => "home",
    "HIVE_HOME" => "hive",
    "XDG_CONFIG_HOME" => "config",
    "XDG_DATA_HOME" => "data",
    "XDG_STATE_HOME" => "state",
    "XDG_CACHE_HOME" => "cache",
    "XDG_BIN_HOME" => "bin",
    "CLAUDE_CONFIG_DIR" => "home/.claude",
    "CODEX_HOME" => "home/.codex",
    "PI_CODING_AGENT_DIR" => "home/.pi/agent",
    "GROK_HOME" => "home/.grok",
    "GH_CONFIG_DIR" => "gh",
    "GIT_CONFIG_GLOBAL" => "gitconfig"
  }.freeze

  def test_operator_user_environment_is_disposable
    root = File.realpath(HIVE_TEST_USER_ROOT)

    assert_equal Dir.tmpdir, File.dirname(root)
    assert_match(/\Ahive-test-user/, File.basename(root))
    USER_ENV_PATHS.each do |name, relative|
      assert_equal File.join(root, relative), File.expand_path(ENV.fetch(name)), name
    end
  end
end
