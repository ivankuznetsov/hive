require "test_helper"
require "hive/commands/service_installer/agent_environment"

class ServiceInstallerAgentEnvironmentTest < Minitest::Test
  include HiveTestHelper

  def test_preserves_first_executable_and_stable_symlink_directory
    with_tmp_dir do |dir|
      version = File.join(dir, "versions", "1", "bin")
      stable = File.join(dir, "current")
      second = File.join(dir, "second")
      unrelated = File.join(dir, "unrelated")
      FileUtils.mkdir_p([ version, second, unrelated ])
      [ version, second ].each do |path|
        File.write(File.join(path, "codex"), "#!/bin/sh\n")
        FileUtils.chmod(0755, File.join(path, "codex"))
      end
      File.symlink(version, stable)
      environment = Hive::Commands::ServiceInstaller::AgentEnvironment.new(
        "PATH" => "#{unrelated}:#{stable}:#{second}:#{stable}"
      )

      assert_equal [ stable ], environment.paths
      assert_empty environment.overrides
    end
  end

  def test_binary_override_precedence_and_basename_resolution
    with_tmp_dir do |dir|
      executable = File.join(dir, "chosen-codex")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0755, executable)
      environment = Hive::Commands::ServiceInstaller::AgentEnvironment.new(
        "PATH" => dir, "HIVE_CODEX_BIN" => "chosen-codex",
        "AGENT_CLI_RUNTIME_CODEX_BIN" => executable
      )

      assert_equal [ dir ], environment.paths
      assert_equal executable, environment.overrides.fetch("HIVE_CODEX_BIN")
      assert_equal executable, environment.overrides.fetch("AGENT_CLI_RUNTIME_CODEX_BIN")
    end
  end

  def test_relative_and_control_byte_search_paths_do_not_enter_service_definitions
    with_tmp_dir do |dir|
      bad = File.join(dir, "bad\nEnvironment=INJECTED=yes")
      FileUtils.mkdir_p(bad)
      File.write(File.join(bad, "codex"), "#!/bin/sh\n")
      FileUtils.chmod(0755, File.join(bad, "codex"))
      environment = Hive::Commands::ServiceInstaller::AgentEnvironment.new(
        "PATH" => ":.:relative:#{bad}"
      )

      assert_empty environment.paths
      assert_empty environment.overrides
      override = Hive::Commands::ServiceInstaller::AgentEnvironment.new(
        "PATH" => dir, "HIVE_CODEX_BIN" => "bad\nEnvironment=INJECTED=yes"
      )
      assert_raises(Hive::ConfigError) { override.overrides }
    end
  end

  def test_unresolvable_explicit_override_is_actionable
    environment = Hive::Commands::ServiceInstaller::AgentEnvironment.new(
      "PATH" => "", "HIVE_CODEX_BIN" => "missing-codex"
    )

    error = assert_raises(Hive::ConfigError) { environment.overrides }
    assert_includes error.message, "HIVE_CODEX_BIN"
    assert_includes error.message, "installation PATH"
  end
end
