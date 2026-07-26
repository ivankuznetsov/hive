require "test_helper"

class TestHelperIsolationTest < Minitest::Test
  def test_global_git_configuration_is_disposable
    configured = File.expand_path(ENV.fetch("GIT_CONFIG_GLOBAL"))
    root = File.realpath(HIVE_TEST_GLOBAL_GIT_CONFIG_ROOT)

    assert_equal File.join(root, "config"), configured
    assert_equal Dir.tmpdir, File.dirname(root)
    assert_match(/\Ahive-test-git-config/, File.basename(root))
  end
end
