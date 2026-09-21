require "test_helper"

class RealUserEnvironmentIsolationSmokeTest < Minitest::Test
  def test_operator_home_is_retained_while_hive_install_paths_are_disposable
    root = File.realpath(HIVE_TEST_USER_ROOT)

    assert_equal "1", ENV.fetch("HIVE_TEST_ALLOW_REAL_USER_ENV")
    refute_equal File.join(root, "home"), File.expand_path(ENV.fetch("HOME"))
    assert_equal File.join(root, "hive-home"), ENV.fetch("HIVE_HOME")
    assert_equal File.join(root, "data"), ENV.fetch("XDG_DATA_HOME")
    assert_equal File.join(root, "bin"), ENV.fetch("XDG_BIN_HOME")
    assert_nil ENV["HIVE_PREFIX"]
  end
end
