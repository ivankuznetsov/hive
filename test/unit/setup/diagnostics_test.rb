require "test_helper"
require "hive/setup/diagnostics"
require "hive/web/app_bundle"

class SetupDiagnosticsTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def executable(dir, name)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def test_missing_gh_reports_auth_install_fix
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }

      result = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1").run
      row = result.results.find { |r| r.name == "gh" }

      assert_equal "missing", row.status
      assert_match(/install/, row.fix_command)
    end
  end

  def test_gh_unauthenticated_reports_login_without_fixing
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = lambda do |argv|
        if argv[1..] == %w[auth status]
          [ "", "not logged in", Status.new(false) ]
        else
          [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ]
        end
      end

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "gh" }

      assert_equal "unauthenticated", row.status
      assert_equal "gh auth login", row.fix_command
    end
  end

  def test_version_too_old_is_classified
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = lambda do |argv|
        return [ "", "", Status.new(true) ] if argv[1..] == %w[auth status]
        return [ "tmux 2.9", "", Status.new(true) ] if File.basename(argv.first) == "tmux"

        [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ]
      end

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "tmux" }

      assert_equal "version_too_old", row.status
      assert_match(/>= 3\.0/, row.detail)
    end
  end

  def test_qmd_missing_is_bootstrappable
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }

      row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1")
                                     .run.results.find { |r| r.name == "qmd" }

      assert_equal "missing", row.status
      assert row.bootstrappable
      assert_nil row.fix_command
    end
  end

  def test_agent_authenticated_via_on_disk_token_without_env_var
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }
      # `claude setup-token` persists ~/.claude/.credentials.json with no env
      # var; the diagnostics engine must not report that as unauthenticated.
      Dir.mktmpdir("hive-home") do |home|
        FileUtils.mkdir_p(File.join(home, ".claude"))
        File.write(File.join(home, ".claude", ".credentials.json"), '{"token":"x"}')

        env = { "PATH" => dir, "HOME" => home }
        row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1", env: env)
                                       .run.results.find { |r| r.name == "claude" }
        assert_equal "ok", row.status
      end
    end
  end

  def test_agent_unauthenticated_when_no_env_and_no_token_file
    Dir.mktmpdir("hive-diag") do |dir|
      %w[git tmux gh claude codex node npm sqlite3].each { |name| executable(dir, name) }
      runner = ->(argv) { [ "#{File.basename(argv.first)} 9.9.9", "", Status.new(true) ] }
      Dir.mktmpdir("hive-home") do |home|
        env = { "PATH" => dir, "HOME" => home }
        row = Hive::Setup::Diagnostics.new(path: dir, runner: runner, ruby_version: "3.4.1", env: env)
                                       .run.results.find { |r| r.name == "claude" }
        assert_equal "unauthenticated", row.status
        assert_equal "claude setup-token", row.fix_command
      end
    end
  end

  def test_result_rejects_unknown_status
    assert_raises(ArgumentError) do
      Hive::Setup::Diagnostics::Result.new(name: "x", status: "bogus", detail: "d",
                                           fix_command: nil, bootstrappable: false)
    end
  end

  def test_qmd_present_reports_ok_with_path
    Dir.mktmpdir("hive-diag") do |dir|
      qmd = executable(dir, "qmd")
      diag = Hive::Setup::Diagnostics.new(path: dir, ruby_version: "3.4.1")

      row = diag.check_qmd

      assert_equal "ok", row.status
      assert_equal qmd, row.detail
      refute row.bootstrappable
    end
  end

  def test_web_bundle_present_and_current_reports_ok_not_bootstrappable
    diag = Hive::Setup::Diagnostics.new(ruby_version: "3.4.1")
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, -> { true }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :stale?, -> { false }) do
        with_replaced_singleton_method(Hive::Web::AppBundle, :app_dir, -> { "/managed/web" }) do
          row = diag.check_web_bundle

          assert_equal "ok", row.status
          assert_equal "/managed/web", row.detail
          refute row.bootstrappable, "a present+current bundle must not be a bootstrap candidate"
        end
      end
    end
  end

  def test_web_bundle_stale_is_version_too_old_but_bootstrappable
    diag = Hive::Setup::Diagnostics.new(ruby_version: "3.4.1")
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, -> { true }) do
      with_replaced_singleton_method(Hive::Web::AppBundle, :stale?, -> { true }) do
        row = diag.check_web_bundle

        assert_equal "version_too_old", row.status
        assert_equal "managed web bundle is stale", row.detail
        assert row.bootstrappable, "a stale-but-present bundle is refreshed by hive setup"
        assert_nil row.fix_command
      end
    end
  end

  def test_web_bundle_load_failure_is_unbootstrappable_missing
    diag = Hive::Setup::Diagnostics.new(ruby_version: "3.4.1")
    with_replaced_singleton_method(Hive::Web::AppBundle, :present?, -> { raise LoadError, "boom" }) do
      row = diag.check_web_bundle

      assert_equal "missing", row.status
      assert_match(/web bundle support failed to load: boom/, row.detail)
      refute row.bootstrappable, "a code-load failure is not something hive setup can bootstrap"
      assert_nil row.fix_command
    end
  end

  def test_sqlite_missing_reports_install_fix
    Dir.mktmpdir("hive-diag") do |dir|
      # Seed everything except sqlite3 so check_sqlite hits the missing branch.
      %w[git tmux gh claude codex node npm].each { |name| executable(dir, name) }
      diag = Hive::Setup::Diagnostics.new(path: dir, ruby_version: "3.4.1")

      row = diag.check_sqlite

      assert_equal "missing", row.status
      assert_equal "sqlite3 is not on PATH", row.detail
      assert_match(/sqlite/, row.fix_command)
      refute row.bootstrappable
    end
  end

  def test_run_command_wraps_timeout_and_syscall_failures_in_failure_status
    diag = Hive::Setup::Diagnostics.new(runner: ->(_argv) { raise Timeout::Error, "timed out" })
    out, err, status = diag.send(:run_command, %w[some cmd])

    assert_equal "", out
    assert_equal "timed out", err
    refute status.success?, "a timed-out probe must yield a non-success status tuple"

    diag2 = Hive::Setup::Diagnostics.new(runner: ->(_argv) { raise Errno::ENOENT, "no such file" })
    out2, err2, status2 = diag2.send(:run_command, %w[missing bin])
    assert_equal "", out2
    assert_match(/no such file/, err2)
    refute status2.success?
  end

  def test_default_run_executes_real_command_and_returns_three_tuple
    # No runner injected → the real default_run (Timeout + Open3.capture3) runs.
    diag = Hive::Setup::Diagnostics.new
    out, err, status = diag.send(:default_run, %w[echo hello])

    assert_equal "hello", out.strip
    assert_equal "", err
    assert status.success?, "a harmless real command must report a success status"
  end

  def test_install_command_is_platform_specific
    diag = Hive::Setup::Diagnostics.new

    with_replaced_singleton_method(diag, :platform, -> { :macos }) do
      assert_equal "brew install node", diag.send(:install_command, "node")
      assert_equal "brew install git", diag.send(:install_command, "git")
    end
    with_replaced_singleton_method(diag, :platform, -> { :linux }) do
      assert_equal "sudo apt install git", diag.send(:install_command, "git")
      assert_equal "sudo apt install sqlite3", diag.send(:install_command, "sqlite")
      assert_equal "sudo apt install nodejs npm", diag.send(:install_command, "node")
    end
    with_replaced_singleton_method(diag, :platform, -> { :other }) do
      assert_equal "install git", diag.send(:install_command, "git")
    end
  end

  def test_platform_detection_maps_host_os_string
    diag = Hive::Setup::Diagnostics.new

    with_host_os("linux-gnu") { assert_equal :linux, diag.send(:platform) }
    with_host_os("solaris2.11") { assert_equal :other, diag.send(:platform) }
    with_host_os("darwin24") { assert_equal :macos, diag.send(:platform) }
  end

  # platform reads RbConfig::CONFIG["host_os"] directly; RbConfig::CONFIG is a
  # plain mutable Hash, so swap the value in place and restore it afterward.
  def with_host_os(value)
    original = RbConfig::CONFIG["host_os"]
    RbConfig::CONFIG["host_os"] = value
    yield
  ensure
    RbConfig::CONFIG["host_os"] = original
  end

  def test_json_shape_is_stable
    result = Hive::Setup::Diagnostics::Aggregate.new(
      results: [
        Hive::Setup::Diagnostics::Result.new(
          name: "gh", status: "missing", detail: "missing", fix_command: "gh auth login", bootstrappable: false
        )
      ]
    )

    assert_equal(
      {
        "ok" => false,
        "results" => [
          {
            "name" => "gh",
            "status" => "missing",
            "detail" => "missing",
            "fix_command" => "gh auth login",
            "bootstrappable" => false
          }
        ]
      },
      result.to_h
    )
  end
end
