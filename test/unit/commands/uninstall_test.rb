require "test_helper"
require "hive/commands/uninstall"

class UninstallCommandTest < Minitest::Test
  include HiveTestHelper

  def setup_install_tree(project)
    FileUtils.mkdir_p(Hive::Paths.config_home)
    FileUtils.mkdir_p(Hive::Paths.cache_home)
    FileUtils.mkdir_p(File.join(Hive::Paths.data_home, "v#{Hive::VERSION}", "bin"))
    FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "projects", "work"))
    FileUtils.mkdir_p(File.join(project, ".hive-state", "stages"))
    File.write(
      Hive::Config.global_config_path,
      {
        "registered_projects" => [
          { "name" => "proj", "path" => project, "hive_state_path" => File.join(project, ".hive-state") }
        ]
      }.to_yaml
    )
  end

  def test_purge_preserves_state_and_project_hive_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        purge: true,
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      refute File.exist?(Hive::Paths.config_home)
      refute File.exist?(Hive::Paths.cache_home)
      refute File.exist?(File.join(Hive::Paths.data_home, "v#{Hive::VERSION}"))
      assert File.exist?(Hive::Paths.state_home)
      # Tighten the invariant: a regression that wipes `projects/work` but
      # leaves the parent `state_home` stub would slip past a bare-parent
      # check, so assert on the actual work payload.
      assert File.exist?(File.join(Hive::Paths.state_home, "projects", "work"))
      assert File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_force_purge_state_removes_accumulated_state_and_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        purge: true,
        force_purge_state: true,
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      refute File.exist?(Hive::Paths.state_home)
      refute File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_hive_home_collapse_skips_config_cache_and_state_deletes
    # `with_xdg_home` (not the bare `with_tmp_dir`) is load-bearing here:
    # `Hive::Paths.bin_home` intentionally ignores HIVE_HOME, so without
    # the HOME / XDG_BIN_HOME isolation that `with_xdg_home` sets up,
    # `Uninstall#remove_user_symlinks` would resolve `bin_home` to the
    # real `~/.local/bin/` and unlink the user's actual hive/hv
    # symlinks during `rake test`. Every other Uninstall test in this
    # file uses `with_xdg_home` for that reason; this one is the lone
    # path that needs to override HIVE_HOME after entering the sandbox.
    with_xdg_home do |dir|
      ENV["HIVE_HOME"] = File.join(dir, "collapsed")
      FileUtils.mkdir_p(ENV.fetch("HIVE_HOME"))
      File.write(Hive::Config.global_config_path, { "registered_projects" => [] }.to_yaml)
      FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "projects", "work"))

      out = StringIO.new
      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert File.exist?(Hive::Paths.config_home)
      assert File.exist?(File.join(Hive::Paths.state_home, "projects", "work"))
      assert_match(/HIVE_HOME collapses/, out.string)
    end
  end

  def test_interactive_prompt_refusal_preserves_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        input: StringIO.new("n\n"),
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_interactive_prompt_acceptance_removes_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        input: StringIO.new("yes\n"),
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      refute File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_safe_unlink_refuses_symlinked_systemd_unit
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      target = File.join(Hive::Paths.cache_home, "target.service")
      FileUtils.mkdir_p(File.dirname(unit))
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "unit\n")
      File.symlink(target, unit)
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      assert File.symlink?(unit)
      assert_match(/refusing to follow symlink/, out.string)
    end
  end

  def test_systemd_disable_failure_leaves_unit_in_place
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { false },
        host_os: "linux"
      ).call

      assert File.exist?(unit)
      assert_match(/leaving .* in place/, out.string)
    end
  end

  def test_systemd_daemon_reload_failure_is_reported
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      calls = 0
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { calls += 1; calls == 1 },
        host_os: "linux"
      ).call

      refute File.exist?(unit)
      assert_match(/daemon-reload failed/, out.string)
    end
  end
end
