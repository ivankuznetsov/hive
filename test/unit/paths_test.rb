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
        assert_equal File.join(dir, "state", "hive", "runtime-control-plane.sqlite3"),
                     Hive::Paths.runtime_control_plane_path
        assert_equal File.join(dir, "cache", "hive"), Hive::Paths.cache_home
        assert_equal File.join(dir, "bin"), Hive::Paths.bin_home
        publish = File.join(dir, "state", "hive", "workflow-publish", "v1")
        assert_equal publish, Hive::Paths.workflow_publish_root
        assert_equal File.join(publish, "receipts"), Hive::Paths.workflow_publish_receipts_root
        assert_equal File.join(publish, "objects"), Hive::Paths.workflow_publish_objects_root
        assert_equal File.join(dir, "state", "hive", "daily-digest", "v1"),
                     Hive::Paths.daily_digest_root
        assert_equal File.join(dir, "state", "hive", "daily-digest", "v1", "deliveries"),
                     Hive::Paths.daily_digest_delivery_root
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

  def test_config_reads_leave_historical_registries_untouched
    with_tmp_dir do |dir|
      home = File.join(dir, "home")
      legacy_paths = [ ".hive-state/registry.yml", "Dev/hive/config.yml" ].map do |relative|
        path = File.join(home, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "registered_projects: []\n")
        path
      end
      with_env("HOME" => home, "HIVE_HOME" => nil,
               "XDG_CONFIG_HOME" => File.join(dir, "config")) do
        assert_empty Hive::Config.registered_projects
        legacy_paths.each { |path| assert_equal "registered_projects: []\n", File.read(path) }
        refute_path_exists File.join(Hive::Paths.config_home, "config.yml")
        refute_path_exists File.join(Hive::Paths.config_home, ".migrated-from")
      end
    end
  end
end
