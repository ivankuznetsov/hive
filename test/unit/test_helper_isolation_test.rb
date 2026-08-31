require "test_helper"
require "hive/task_counter"

class TestHelperIsolationTest < Minitest::Test
  include HiveTestHelper

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

  def test_runtime_fixture_restores_dynamic_database_defaults
    prior = {
      lock_defined: Hive::Lock.instance_variable_defined?(:@task_lease_repository),
      lock: Hive::Lock.instance_variable_get(:@task_lease_repository),
      counter_defined: Hive::TaskCounter.instance_variable_defined?(:@database),
      counter: Hive::TaskCounter.instance_variable_get(:@database)
    }
    Hive::Lock.remove_instance_variable(:@task_lease_repository) if prior[:lock_defined]
    Hive::TaskCounter.remove_instance_variable(:@database) if prior[:counter_defined]

    prepare_test_runtime_project(tracked_tmp_dir("hive-test-project"))
    cleanup_test_task_leases

    refute Hive::Lock.instance_variable_defined?(:@task_lease_repository)
    refute Hive::TaskCounter.instance_variable_defined?(:@database)
  ensure
    cleanup_test_task_leases
    Hive::Lock.task_lease_repository = prior[:lock] if prior&.fetch(:lock_defined)
    Hive::TaskCounter.database = prior[:counter] if prior&.fetch(:counter_defined)
  end

  def test_test_boundary_disconnects_explicit_databases_and_clears_default_hive_homes
    database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(tracked_tmp_dir("hive-test-runtime-boundary"), "runtime.sqlite3")
    ).migrate!
    home = File.join(HIVE_TEST_USER_ROOT, "home")
    hive_homes = %w[.local/state/hive .local/share/hive .config/hive].map do |relative|
      File.join(home, relative).tap { |path| FileUtils.mkdir_p(path) }
    end

    send(:reset_test_runtime_owners!)

    assert database.disconnected?
    hive_homes.each { |path| refute_path_exists path }
  ensure
    database&.disconnect
  end
end
