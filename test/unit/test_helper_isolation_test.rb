require "test_helper"

class TestHelperIsolationTest < Minitest::Test
  USER_ENV_OVERRIDES = %w[
    HIVE_HOME
    XDG_CONFIG_HOME
    XDG_DATA_HOME
    XDG_STATE_HOME
    XDG_CACHE_HOME
    XDG_BIN_HOME
    CLAUDE_CONFIG_DIR
    CODEX_HOME
    PI_CODING_AGENT_DIR
    GROK_HOME
    GH_CONFIG_DIR
    GIT_CONFIG_GLOBAL
  ].freeze

  def test_operator_user_environment_is_disposable
    root = File.realpath(HIVE_TEST_USER_ROOT)

    assert_equal Dir.tmpdir, File.dirname(root)
    assert_match(/\Ahive-test-user/, File.basename(root))
    assert_equal File.join(root, "home"), File.expand_path(ENV.fetch("HOME"))
    USER_ENV_OVERRIDES.each { |name| refute ENV.key?(name), name }
  end
end
