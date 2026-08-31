require "test_helper"
require "hive/task_counter"
require "json"
require "open3"
require "rbconfig"

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

  def test_real_user_environment_escape_hatch_rejects_non_smoke_processes
    _stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => "1",
        "HIVE_TEST_REQUESTED_FILES" => "test/smoke/forged_test.rb",
        "HIVE_HOME" => nil
      },
      RbConfig.ruby,
      "-Itest",
      "-e",
      'require "test_helper"',
      chdir: File.expand_path("../..", __dir__)
    )

    refute status.success?
    assert_match(/only supported for test\/smoke/, stderr)
  end

  def test_real_user_environment_escape_hatch_isolates_hive_home
    operator_home = tracked_tmp_dir("hive-test-operator-home")
    code = <<~'RUBY'
      $0 = File.expand_path("test/smoke/environment_probe_test.rb")
      require "json"
      require "test_helper"
      puts "HIVE_ENV_PROBE=#{JSON.generate(
        "home" => ENV["HOME"],
        "test_root" => HIVE_TEST_USER_ROOT,
        "hive_home" => ENV["HIVE_HOME"],
        "data_home" => Hive::Paths.data_home,
        "bin_home" => Hive::Paths.bin_home,
        "xdg_data_home" => ENV["XDG_DATA_HOME"],
        "xdg_bin_home" => ENV["XDG_BIN_HOME"],
        "hive_prefix" => ENV["HIVE_PREFIX"]
      )}"
    RUBY
    stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => "1",
        "HOME" => operator_home,
        "HIVE_HOME" => nil,
        "HIVE_PREFIX" => File.join(operator_home, "prefix"),
        "XDG_DATA_HOME" => File.join(operator_home, "data"),
        "XDG_BIN_HOME" => File.join(operator_home, "bin")
      },
      RbConfig.ruby,
      "-Itest",
      "-e",
      code,
      chdir: File.expand_path("../..", __dir__)
    )

    assert status.success?, stderr
    probe = JSON.parse(stdout.lines.grep(/^HIVE_ENV_PROBE=/).fetch(0).split("=", 2).last)
    assert_equal operator_home, probe.fetch("home")
    test_root = probe.fetch("test_root")
    assert_match(%r{/hive-test-user[^/]*\z}, test_root)
    %w[hive_home data_home bin_home xdg_data_home xdg_bin_home].each do |name|
      path = probe.fetch(name)
      assert path.start_with?("#{test_root}/"), "#{name}=#{path.inspect} must stay under #{test_root}"
      refute path.start_with?("#{operator_home}/"), "#{name}=#{path.inspect} must not use operator HOME"
    end
    assert_nil probe.fetch("hive_prefix")
  end

  def test_real_user_environment_escape_hatch_accepts_bin_test_smoke_file
    _stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => "1",
        "HIVE_HOME" => nil
      },
      "bin/test",
      "test/smoke/real_user_environment_isolation_smoke_test.rb",
      chdir: File.expand_path("../..", __dir__)
    )

    assert status.success?, stderr
  end

  def test_real_user_environment_escape_hatch_rejects_mixed_bin_test_files
    _stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => "1",
        "HIVE_HOME" => nil
      },
      "bin/test",
      "test/smoke/real_user_environment_isolation_smoke_test.rb",
      "test/unit/paths_test.rb",
      chdir: File.expand_path("../..", __dir__)
    )

    refute status.success?
    assert_match(/only supported for test\/smoke/, stderr)
  end

  def test_real_user_environment_escape_hatch_rejects_unit_program_with_smoke_argv
    _stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => "1",
        "HIVE_HOME" => nil
      },
      RbConfig.ruby,
      "-Itest",
      "test/unit/paths_test.rb",
      "test/smoke/real_user_environment_isolation_smoke_test.rb",
      chdir: File.expand_path("../..", __dir__)
    )

    refute status.success?
    assert_match(/only supported for test\/smoke/, stderr)
  end

  def test_rake_smoke_scopes_real_user_environment_to_its_child
    _stdout, stderr, status = Open3.capture3(
      {
        "HIVE_TEST_ALLOW_REAL_USER_ENV" => nil,
        "OPENAI_API_KEY" => nil,
        "OPENROUTER_API_KEY" => nil,
        "TESTOPTS" => "--name=/test_operator_home_is_retained_while_hive_install_paths_are_disposable/"
      },
      "bundle",
      "exec",
      "rake",
      "smoke",
      chdir: File.expand_path("../..", __dir__)
    )

    assert status.success?, stderr
    refute ENV.key?("HIVE_TEST_ALLOW_REAL_USER_ENV")
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
