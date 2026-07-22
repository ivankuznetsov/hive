require "test_helper"
require "hive/managed_git"

class ManagedGitTest < Minitest::Test
  include HiveTestHelper

  def test_controller_commands_do_not_execute_agent_git_helpers
    with_tmp_git_repo do |repo|
      fsmonitor_marker = File.join(repo, "fsmonitor-ran")
      fsmonitor = File.join(repo, "fsmonitor-helper")
      File.write(fsmonitor, <<~SH)
        #!/bin/sh
        : > "#{fsmonitor_marker}"
        printf '\n'
      SH
      File.chmod(0o755, fsmonitor)
      run!("git", "-C", repo, "config", "core.fsmonitor", fsmonitor)

      run!("git", "-C", repo, "status", "--porcelain=v1")
      assert File.exist?(fsmonitor_marker), "precondition: ordinary Git must invoke the helper"
      FileUtils.rm_f(fsmonitor_marker)

      _out, err, status = Hive::ManagedGit.capture3(repo, "status", "--porcelain=v1")
      assert status.success?, err
      refute File.exist?(fsmonitor_marker)
      run!("git", "-C", repo, "config", "--unset", "core.fsmonitor")
      run!("git", "-C", repo, "update-index", "--no-fsmonitor")

      diff_marker = File.join(repo, "external-diff-ran")
      diff_helper = File.join(repo, "external-diff-helper")
      File.write(diff_helper, <<~SH)
        #!/bin/sh
        : > "#{diff_marker}"
      SH
      File.chmod(0o755, diff_helper)
      File.write(File.join(repo, ".gitattributes"), "*.txt diff=agent-helper\n")
      File.write(File.join(repo, "managed-git.txt"), "before\n")
      run!("git", "-C", repo, "add", ".gitattributes", "managed-git.txt")
      run!("git", "-C", repo, "commit", "-m", "add managed git fixture", "--quiet")
      run!("git", "-C", repo, "config", "diff.agent-helper.command", diff_helper)
      File.write(File.join(repo, "managed-git.txt"), "after\n")

      run!("git", "-C", repo, "diff", "--ext-diff")
      assert File.exist?(diff_marker), "precondition: ordinary Git must invoke the external diff"
      FileUtils.rm_f(diff_marker)

      _out, err, status = Hive::ManagedGit.capture3(repo, "diff")
      assert status.success?, err
      refute File.exist?(diff_marker)
    end
  end

  def test_environment_drops_agent_selected_git_executables
    with_env(
      "GIT_SSH_COMMAND" => "/tmp/attacker-ssh",
      "GIT_ASKPASS" => "/tmp/attacker-askpass",
      "GIT_CONFIG_COUNT" => "1"
    ) do
      env = Hive::ManagedGit.environment
      refute env.key?("GIT_SSH_COMMAND")
      refute env.key?("GIT_ASKPASS")
      refute env.key?("GIT_CONFIG_COUNT")
      assert_equal File::NULL, env.fetch("GIT_CONFIG_GLOBAL")
      assert_equal "0", env.fetch("GIT_TERMINAL_PROMPT")
    end
  end

  def test_command_allowlist_blocks_unneeded_git_surfaces
    assert_raises(ArgumentError) do
      Hive::ManagedGit.command("/tmp/repo", "config", "alias.escape", "!sh")
    end
  end
end
