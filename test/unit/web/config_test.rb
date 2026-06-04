require "test_helper"
require "hive/config"

class WebConfigTest < Minitest::Test
  include HiveTestHelper

  def test_global_web_defaults_are_state_home_based
    with_tmp_global_config do
      cfg = Hive::Config.load_global_web

      assert_equal "127.0.0.1", cfg["bind"]
      assert_equal 4567, cfg["port"]
      assert_match(/\.web\.session_secret\z/, cfg["session_secret_file"])
    end
  end

  def test_invalid_web_port_is_rejected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "web" => { "port" => 70_000 } }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_web }
      assert_match(/web\.port/, err.message)
    end
  end
end
