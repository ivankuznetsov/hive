require "test_helper"
require "hive/paths"

class PathsTest < Minitest::Test
  include HiveTestHelper

  def test_job_schema_exact_roots_are_private_to_the_internal_child
    with_tmp_dir do |dir|
      exact_config = File.join(dir, "exact-config")
      exact_state = File.join(dir, "exact-state")
      environment = {
        "HOME" => dir,
        "HIVE_HOME" => File.join(dir, "ordinary"),
        Hive::Paths::JOB_SCHEMA_CONFIG_HOME => exact_config,
        Hive::Paths::JOB_SCHEMA_STATE_HOME => exact_state
      }

      with_env(environment) do
        assert_equal File.join(dir, "ordinary"), Hive::Paths.config_home
        assert_equal File.join(dir, "ordinary"), Hive::Paths.state_home
      end
      with_env(
        environment.merge(
          Hive::Paths::JOB_SCHEMA_MIGRATION_INTERNAL => "1"
        )
      ) do
        assert_equal exact_config, Hive::Paths.config_home
        assert_equal exact_state, Hive::Paths.state_home
      end
    end
  end

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
        assert_equal File.join(dir, "state", "hive", "operational", "daemon-snapshot.json"),
                     Hive::Paths.operational_snapshot_path
        assert_equal File.join(dir, "cache", "hive"), Hive::Paths.cache_home
        assert_equal File.join(dir, "bin"), Hive::Paths.bin_home
        attempts = File.join(dir, "state", "hive", "attempts", "v2")
        assert_equal attempts, Hive::Paths.attempts_root
        assert_equal File.join(attempts, "records"), Hive::Paths.attempt_records_root
        assert_equal File.join(attempts, "logs"), Hive::Paths.attempt_logs_root
        assert_equal File.join(attempts, "outputs"), Hive::Paths.attempt_outputs_root
        assert_equal File.join(attempts, "generation-locks"), Hive::Paths.attempt_generation_locks_root
        publish = File.join(dir, "state", "hive", "workflow-publish", "v1")
        assert_equal publish, Hive::Paths.workflow_publish_root
        assert_equal File.join(publish, "receipts"), Hive::Paths.workflow_publish_receipts_root
        assert_equal File.join(publish, "bundles"), Hive::Paths.workflow_publish_bundles_root
        assert_equal File.join(publish, "locks"), Hive::Paths.workflow_publish_locks_root
        assert_equal File.join(publish, "objects"), Hive::Paths.workflow_publish_objects_root
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
        # The empty legacy parent dir should be reaped so a future
        # re-migration doesn't see stale state. If something else under
        # ~/.hive-state lingers (logs, locks), reap should be a no-op,
        # but the registry-only fixture above leaves it empty.
        refute File.exist?(legacy_dir),
               "empty legacy parent #{legacy_dir} should be removed after migration"
      end
    end
  end

  def test_legacy_registry_migration_preserves_non_empty_legacy_dir
    with_tmp_dir do |dir|
      home = File.join(dir, "home")
      legacy_dir = File.join(home, ".hive-state")
      sibling = File.join(legacy_dir, "daemon.log")
      FileUtils.mkdir_p(legacy_dir)
      File.write(File.join(legacy_dir, "registry.yml"), { "registered_projects" => [] }.to_yaml)
      File.write(sibling, "keep\n")

      with_env(
        "HOME" => home,
        "HIVE_HOME" => nil,
        "XDG_CONFIG_HOME" => File.join(dir, "config")
      ) do
        capture_io { Hive::Paths.ensure_migrated! }
        assert File.exist?(File.join(dir, "config", "hive", "config.yml"))
        assert File.exist?(sibling), "non-registry legacy content must not be reaped"
        refute File.exist?(File.join(legacy_dir, "registry.yml"))
      end
    end
  end

  def test_ensure_migrated_is_idempotent
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
        target = File.join(dir, "config", "hive", "config.yml")
        first_payload = File.read(target)
        # Second call should not overwrite or crash — guarded by the
        # `return if File.exist?(File.join(config_home, "config.yml"))`
        # invariant in ensure_migrated!.
        Hive::Paths.ensure_migrated!
        assert_equal first_payload, File.read(target),
                     "second ensure_migrated! must not overwrite the migrated config"
      end
    end
  end

  def test_ensure_migrated_skips_when_hive_home_set
    # HIVE_HOME collapses all XDG dirs onto one path — running the
    # legacy registry migration there would overwrite a user's existing
    # `<HIVE_HOME>/config.yml`. The guard early-returns; this test
    # locks that contract.
    with_tmp_dir do |dir|
      home = File.join(dir, "home")
      legacy = File.join(home, ".hive-state", "registry.yml")
      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, { "registered_projects" => [] }.to_yaml)

      with_env(
        "HOME" => home,
        "HIVE_HOME" => File.join(dir, "legacy"),
        "XDG_CONFIG_HOME" => File.join(dir, "config")
      ) do
        FileUtils.mkdir_p(File.join(dir, "legacy"))
        Hive::Paths.ensure_migrated!
        assert File.exist?(legacy),
               "legacy registry must remain when HIVE_HOME is set"
        refute File.exist?(File.join(dir, "config", "hive", "config.yml"))
      end
    end
  end
end
