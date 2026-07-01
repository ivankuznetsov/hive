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

  # Each case writes a single invalid `web.*` value (deep_merge keeps the
  # other defaults valid) and asserts load_global_web raises the matching
  # ConfigError, mirroring test_invalid_web_port_is_rejected above.
  def assert_web_config_error(web_override, expected_message)
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "web" => web_override }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_web }
      assert_match(expected_message, err.message)
    end
  end

  def test_non_hash_web_is_rejected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "web" => "not-a-hash" }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_web }
      assert_match(/web in .* must be a Hash/, err.message)
    end
  end

  def test_blank_web_bind_is_rejected
    assert_web_config_error({ "bind" => "   " }, /web\.bind/)
  end

  def test_non_url_web_origin_is_rejected
    assert_web_config_error({ "origin" => "ftp://example.test" }, /web\.origin/)
  end

  def test_non_hash_web_github_is_rejected
    assert_web_config_error({ "github" => "nope" }, /web\.github in .* must be a Hash/)
  end

  def test_blank_web_github_owner_is_rejected
    assert_web_config_error({ "github" => { "owner" => "" } }, /web\.github\.owner/)
  end

  def test_blank_web_session_secret_file_is_rejected
    assert_web_config_error({ "session_secret_file" => "  " }, /web\.session_secret_file/)
  end

  def test_non_boolean_web_local_loopback_is_rejected
    # local_loopback is the opt-out for the loopback no-auth bypass; a non-bool
    # (e.g. the string "yes") must be rejected so a typo can't silently leave
    # the bypass enabled or disabled ambiguously.
    assert_web_config_error({ "local_loopback" => "yes" }, /web\.local_loopback.*must be true or false/)
  end

  def test_boolean_web_local_loopback_is_accepted
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "web" => { "local_loopback" => false } }.to_yaml)

      assert_equal false, Hive::Config.load_global_web["local_loopback"],
                   "an explicit boolean local_loopback must load without error"
    end
  end
end
