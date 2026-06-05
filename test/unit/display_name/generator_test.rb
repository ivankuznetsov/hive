require "test_helper"
require "hive/display_name/generator"
require "hive/task"

# Exercises the process-management and error-recovery branches of the
# display-name Generator. The agent here is a real throwaway shell script
# (never a stubbed AI API) so the timeout / signal / reap logic runs against
# a genuine subprocess.
class DisplayNameGeneratorTest < Minitest::Test
  include HiveTestHelper

  def test_timeout_sec_reads_config_and_falls_back_on_bad_value
    with_generator(display_name_timeout_sec: 5) do |gen|
      assert_equal 5, gen.send(:timeout_sec)
    end

    with_generator(display_name_timeout_sec: "not-a-number") do |gen|
      assert_equal Hive::DisplayName::Generator::DEFAULT_TIMEOUT_SEC, gen.send(:timeout_sec),
                   "unparseable timeout must fall back to the default"
    end
  end

  def test_process_group_returns_pgid_for_live_child_and_pid_on_esrch
    with_generator do |gen|
      pid = Process.spawn("sleep", "30", pgroup: true)
      begin
        assert_equal Process.getpgid(pid), gen.send(:process_group, pid),
                     "live child must resolve to its real process group"
      ensure
        Process.kill("KILL", pid)
        Process.wait(pid)
      end

      # A reaped pid has no process group: getpgid raises ESRCH and the
      # method falls back to the pid itself.
      assert_equal pid, gen.send(:process_group, pid),
                   "ESRCH on a dead pid must fall back to the pid"
    end
  end

  def test_kill_group_signals_real_group_and_swallows_esrch
    with_generator do |gen|
      pid = Process.spawn("sleep", "30", pgroup: true)
      pgid = Process.getpgid(pid)
      gen.send(:kill_group, pgid, "TERM")
      _, status = Process.wait2(pid)
      assert status.signaled?, "TERM to the real group must terminate the child"
      assert_equal Signal.list["TERM"], status.termsig

      # Killing a group that no longer exists raises ESRCH, which is
      # swallowed and returns nil.
      assert_nil gen.send(:kill_group, pgid, "TERM"),
                 "ESRCH on a dead group must be swallowed"
    end
  end

  def test_exit_code_for_nil_exited_signaled_and_stopped
    with_generator do |gen|
      assert_nil gen.send(:exit_code, nil)

      _, exited = Process.wait2(Process.spawn("sh", "-c", "exit 3"))
      assert_equal 3, gen.send(:exit_code, exited)

      pid = Process.spawn("sleep", "30")
      Process.kill("KILL", pid)
      _, signaled = Process.wait2(pid)
      assert_equal(-Signal.list["KILL"], gen.send(:exit_code, signaled),
                   "signaled status must map to negative termsig")

      # A stopped (not exited, not signaled) status hits the final nil
      # fallback.
      stopped_pid = Process.spawn("sleep", "30")
      begin
        Process.kill("STOP", stopped_pid)
        _, stopped = Process.wait2(stopped_pid, Process::WUNTRACED)
        refute stopped.exited?
        refute stopped.signaled?
        assert_nil gen.send(:exit_code, stopped),
                   "a merely-stopped status must yield nil"
      ensure
        Process.kill("KILL", stopped_pid)
        Process.wait(stopped_pid)
      end
    end
  end

  def test_wait_with_timeout_terminates_overrunning_child
    with_generator(display_name_timeout_sec: 0) do |gen|
      pid = Process.spawn("sleep", "30", pgroup: true)
      pgid = Process.getpgid(pid)

      status = gen.send(:wait_with_timeout, pid, pgid)

      assert status.signaled?, "an overrunning child must be killed and reaped"
    end
  end

  def test_wait_with_timeout_returns_nil_when_child_already_reaped
    with_generator do |gen|
      pid = Process.spawn("sh", "-c", "exit 0")
      Process.wait(pid)

      assert_nil gen.send(:wait_with_timeout, pid, pid),
                 "reaping an already-reaped pid raises ECHILD and yields nil"
    end
  end

  def test_original_text_reads_state_file_and_falls_back_on_read_error
    with_generator do |gen, task|
      File.write(task.state_file, "the original idea text")
      assert_equal "the original idea text", gen.send(:original_text)

      # A directory at the state-file path: File.exist? is true but
      # File.read raises EISDIR, so it falls back to the slug.
      File.delete(task.state_file)
      FileUtils.mkdir_p(task.state_file)
      assert_equal task.slug, gen.send(:original_text),
                   "an unreadable state file must fall back to the slug"
    end
  end

  def test_commit_name_swallows_git_error_when_state_is_not_a_repo
    # The task's .hive-state is a plain directory, not a git repo, so
    # GitOps#hive_commit raises Hive::GitError, which commit_name swallows.
    with_generator do |gen|
      assert_nil gen.send(:commit_name),
                 "a GitError during commit must be swallowed"
    end
  end

  def test_call_swallows_unexpected_errors
    with_generator do |gen, task|
      FileUtils.mkdir_p(task.folder)
      gen.define_singleton_method(:generate_name) { "A Readable Name" }
      gen.define_singleton_method(:commit_name) { raise "boom from commit" }

      assert_nil gen.call, "an unexpected StandardError in call must be swallowed"
    end
  end

  private

  # Builds a real task folder (valid PATH_RE) plus a config that points the
  # execute-stage agent's bin at a throwaway script, yields a Generator and
  # its Task. `.hive-state` is intentionally NOT a git repo here.
  def with_generator(**config_overrides)
    with_tmp_dir do |root|
      slug = "sample-task-260603-aaaa"
      folder = File.join(root, ".hive-state", "stages", "1-inbox", slug)
      FileUtils.mkdir_p(folder)

      bin = File.join(root, "fake-display-agent")
      File.write(bin, "#!/bin/sh\nprintf 'noop\\n'\nexit 0\n")
      FileUtils.chmod(0o755, bin)

      cfg = {
        "execute" => { "agent" => "claude" },
        "agents" => { "claude" => { "bin" => bin } }
      }.merge(config_overrides.transform_keys(&:to_s))

      task = Hive::Task.new(folder)
      gen = Hive::DisplayName::Generator.new(task, cfg: cfg)
      yield gen, task
    end
  end
end
