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

  def test_absolute_gh_binary_is_embedded_in_credential_helper
    command = Hive::ManagedGit.command(
      "/tmp/repo", "status", env: { "HIVE_GH_BIN" => "/usr/bin/true" }
    )

    assert_includes command,
                    "credential.https://github.com.helper=!/usr/bin/true auth git-credential"
  end

  def test_gh_binary_override_must_be_an_absolute_executable
    error = assert_raises(ArgumentError) do
      Hive::ManagedGit.command(
        "/tmp/repo", "status", env: { "HIVE_GH_BIN" => "gh" }
      )
    end

    assert_match(/absolute executable file/, error.message)
  end

  def test_capture_timeout_terminates_the_process_group
    Dir.mktmpdir("managed-git-timeout") do |dir|
      fake_git = File.join(dir, "git")
      pid_file = File.join(dir, "pid")
      File.write(fake_git, <<~SH)
        #!/bin/sh
        printf '%s' "$$" > #{Shellwords.escape(pid_file)}
        trap '' TERM
        /usr/bin/sleep 30
      SH
      File.chmod(0o755, fake_git)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _out, err, status = with_env("PATH" => dir) do
        Hive::ManagedGit.capture3(
          dir, "status", timeout_sec: 0.1
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute status.success?
      assert_match(/timed out after 0.1s/, err)
      assert_operator elapsed, :<, 2
      pid = Integer(File.read(pid_file))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      group_gone = loop do
        Process.kill(0, -pid)
        break false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      rescue Errno::ESRCH
        break true
      end
      assert group_gone, "timed-out managed Git process group still exists"
    end
  end

  def test_capture_timeout_must_be_positive
    assert_raises(ArgumentError) do
      Hive::ManagedGit.capture3("/tmp/repo", "status", timeout_sec: 0)
    end
  end

  def test_bounded_capture_preserves_overflow_when_process_already_exited
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "large.txt"), "x" * 65_536)
      run!("git", "-C", repo, "add", "large.txt")
      signals = []
      missing = lambda do |signal, pid|
        signals << [ signal, pid ]
        raise Errno::ESRCH
      end
      with_replaced_singleton_method(Process, :kill, missing) do
        out, _err, status, overflow = Hive::ManagedGit.capture3_bounded(
          repo, "show", ":large.txt", max_stdout_bytes: 1024
        )
        assert_equal "x" * 1024, out
        assert status.success?
        assert overflow
      end
      assert_equal 1, signals.size
      assert_equal "KILL", signals.first.first
      assert_operator signals.first.last, :<, 0
    end
  end

  def test_timeout_cleanup_tolerates_completed_processes_and_failed_readers
    reader = Thread.new { raise "reader failed" }
    reader.report_on_exception = false
    assert_raises(RuntimeError) { reader.join }

    assert_equal "", Hive::ManagedGit.send(:thread_value, reader)
    assert_nil Hive::ManagedGit.send(:terminate_process_group, 2_147_483_647)
  end
end
