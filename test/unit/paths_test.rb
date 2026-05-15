require "test_helper"
require "hive/paths"

class PathsTest < Minitest::Test
  include HiveTestHelper

  def with_env(values)
    old = values.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_xdg_paths_respect_env_vars
    with_tmp_dir do |dir|
      with_env(
        "HOME" => File.join(dir, "home"),
        "HIVE_HOME" => nil,
        "XDG_CONFIG_HOME" => File.join(dir, "config"),
        "XDG_DATA_HOME" => File.join(dir, "data"),
        "XDG_STATE_HOME" => File.join(dir, "state"),
        "XDG_CACHE_HOME" => File.join(dir, "cache"),
        "XDG_BIN_HOME" => File.join(dir, "bin")
      ) do
        assert_equal File.join(dir, "config", "hive"), Hive::Paths.config_home
        assert_equal File.join(dir, "data", "hive"), Hive::Paths.data_home
        assert_equal File.join(dir, "state", "hive"), Hive::Paths.state_home
        assert_equal File.join(dir, "cache", "hive"), Hive::Paths.cache_home
        assert_equal File.join(dir, "bin"), Hive::Paths.bin_home
      end
    end
  end

  def test_hive_home_remains_legacy_override
    with_tmp_dir do |dir|
      with_env(
        "HIVE_HOME" => File.join(dir, "legacy"),
        "XDG_CONFIG_HOME" => File.join(dir, "config"),
        "XDG_DATA_HOME" => File.join(dir, "data"),
        "XDG_STATE_HOME" => File.join(dir, "state"),
        "XDG_CACHE_HOME" => File.join(dir, "cache")
      ) do
        assert_equal File.join(dir, "legacy"), Hive::Paths.config_home
        assert_equal File.join(dir, "legacy"), Hive::Paths.data_home
        assert_equal File.join(dir, "legacy"), Hive::Paths.state_home
        assert_equal File.join(dir, "legacy"), Hive::Paths.cache_home
      end
    end
  end

  def test_legacy_registry_migrates_once_to_xdg_config
    with_tmp_dir do |dir|
      home = File.join(dir, "home")
      legacy_dir = File.join(home, ".hive-state")
      FileUtils.mkdir_p(legacy_dir)
      File.write(File.join(legacy_dir, "registry.yml"), { "registered_projects" => [] }.to_yaml)

      with_env(
        "HOME" => home,
        "HIVE_HOME" => nil,
        "XDG_CONFIG_HOME" => File.join(dir, "config")
      ) do
        Hive::Paths.ensure_migrated!
        assert File.exist?(File.join(dir, "config", "hive", "config.yml"))
        refute File.exist?(File.join(legacy_dir, "registry.yml"))
      end
    end
  end
end
