require "test_helper"
require "hive/claude_launcher"
require "hive/markers"
require "hive/stages/base"
require "hive/stages/execute"
require "hive/task"
require "hive/worktree"

# Integration coverage for `Execute.run_pass` under `claude.mode: tmux`.
# Stubs `Hive::ClaudeLauncher.launch!` to return shapes that match the
# tmux envelope contract (`{status:, log_label:, final_message:,
# final_message_source:}`) and walks both the commit path and the
# research-mode-no-commit path to guarantee:
#
#   1. A clean tmux spawn produces EXECUTE_COMPLETE (the runner writes
#      the marker; the agent does not, see templates/execute_prompt.md.erb).
#   2. Research-mode parity: when the agent commits no worktree change
#      but emits a non-empty final_message, the runner still lands
#      EXECUTE_COMPLETE mode=research — same outcome as headless.
#
# Both branches were silently broken by the original tmux envelope
# (`{status: marker.name, log_label: …}` missing final_message keys);
# this test pins the contract so a future regression surfaces in CI
# instead of as a no-commit "execute_waiting" mystery on real tasks.
class ExecuteTmuxEnvelopeTest < Minitest::Test
  include HiveTestHelper

  def test_tmux_execute_marks_complete_on_clean_commit_spawn
    with_tmp_execute_task do |task, worktree_path|
      cfg = base_cfg
      write_worktree_pointer!(task, worktree_path)

      stub_launch_envelope!(
        status: :ok,
        final_message: "implemented U1 + U2; tests green",
        final_message_source: :plain,
        before_return: -> { produce_commit!(worktree_path) }
      ) do
        result = Hive::Stages::Execute.run_pass(task, cfg, worktree_path)

        assert_equal :execute_complete, result[:status],
                     "clean tmux spawn + new commit must land EXECUTE_COMPLETE; " \
                     "missing final_message used to silently fall into execute_waiting"
        marker = Hive::Markers.current(task.state_file)
        assert_equal :execute_complete, marker.name
      end
    end
  end

  def test_tmux_execute_research_mode_accepts_plain_final_message
    with_tmp_execute_task do |task, worktree_path|
      cfg = base_cfg
      write_research_plan!(task)
      write_worktree_pointer!(task, worktree_path)

      stub_launch_envelope!(
        status: :ok,
        final_message: "research summary: option A vs option B trade-offs",
        final_message_source: :plain
      ) do
        # Deliberately do NOT touch the worktree — research-mode skips
        # the "no_worktree_changes" guard when a final_message is present.
        result = Hive::Stages::Execute.run_pass(task, cfg, worktree_path)

        assert_equal :execute_complete, result[:status],
                     "research-mode tmux spawn must accept :plain final_message " \
                     "(only the headless JSON-stream path produces :structured)"
        marker = Hive::Markers.current(task.state_file)
        assert_equal :execute_complete, marker.name
        assert_equal "research", marker.attrs["mode"]
      end
    end
  end

  def test_tmux_execute_research_mode_pauses_when_final_message_empty
    with_tmp_execute_task do |task, worktree_path|
      cfg = base_cfg
      write_research_plan!(task)
      write_worktree_pointer!(task, worktree_path)

      stub_launch_envelope!(
        status: :ok,
        final_message: "",
        final_message_source: nil
      ) do
        result = Hive::Stages::Execute.run_pass(task, cfg, worktree_path)

        assert_equal :execute_waiting, result[:status]
        marker = Hive::Markers.current(task.state_file)
        assert_equal "missing_research_output", marker.attrs["reason"]
      end
    end
  end

  private

  def base_cfg
    {
      "claude" => { "mode" => "tmux" },
      "execute" => { "agent" => "claude" },
      "worktree_root" => "/tmp/__hive_unused__"
    }
  end

  def with_tmp_execute_task
    with_tmp_git_repo do |project|
      stage_dir = File.join(project, ".hive-state", "stages", "4-execute", "tmux-envelope-test")
      FileUtils.mkdir_p(stage_dir)
      task = Hive::Task.new(stage_dir)
      File.write(File.join(task.folder, "plan.md"), "# plan\n\n## U1\n- [ ] write code\n")
      Dir.mktmpdir("hive-tmux-envelope-worktree") do |worktree_root|
        worktree_path = File.join(worktree_root, "wt")
        run!("git", "-C", project, "worktree", "add", "-b", "tmux-envelope-test", worktree_path)
        yield(task, worktree_path)
      end
    end
  end

  def produce_commit!(worktree_path)
    File.write(File.join(worktree_path, "U1.txt"), "implemented U1\n")
    run!("git", "-C", worktree_path, "add", "U1.txt")
    run!("git", "-C", worktree_path, "commit", "-m", "feat: U1 implemented", "--quiet")
  end

  def write_worktree_pointer!(task, worktree_path)
    pointer = {
      "path" => worktree_path,
      "branch" => "tmux-envelope-test",
      "execute_base_head" => Hive::GitOps.new(worktree_path).head_sha
    }
    File.write(task.worktree_yml_path, pointer.to_yaml)
  end

  def write_research_plan!(task)
    File.write(File.join(task.folder, "plan.md"), <<~MD)
      ---
      execution_mode: research
      ---

      # Research plan

      ## Question
      - [ ] Investigate option A vs option B
    MD
  end

  def stub_launch_envelope!(status:, final_message:, final_message_source:, before_return: nil)
    original = Hive::ClaudeLauncher.singleton_class.instance_method(:launch!)
    envelope = {
      status: status,
      log_label: "execute-impl",
      final_message: final_message,
      final_message_source: final_message_source
    }
    Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
      before_return.call if before_return
      envelope
    end
    yield
  ensure
    Hive::ClaudeLauncher.singleton_class.send(:define_method, :launch!, original) if original
  end
end
