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
end
