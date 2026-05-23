require "test_helper"
require "hive/agent_profiles"
require "hive/stages/execute"
require "hive/stages/finalize"
require "hive/stages/open_pr"
require "hive/stages/plan"
require "hive/stages/artifacts"
require "hive/stages/brainstorm"

class ClaudeModeDispatchTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :project_root, :folder, :state_file, :stage_name, :slug,
    keyword_init: true
  )

  def with_spawn_capture
    captured = []
    singleton = Hive::Stages::Base.singleton_class
    original_agent = singleton.instance_method(:spawn_agent)
    original_claude = singleton.instance_method(:spawn_claude!)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **kwargs|
      captured << { launcher: :headless, task: task, kwargs: kwargs }
      { status: :ok }
    end
    Hive::Stages::Base.define_singleton_method(:spawn_claude!) do |task, cfg, **kwargs|
      captured << { launcher: :claude, task: task, cfg: cfg, kwargs: kwargs }
      { status: :ok }
    end
    yield captured
  ensure
    singleton.define_method(:spawn_agent, original_agent)
    singleton.define_method(:spawn_claude!, original_claude)
  end

  def make_task(dir, stage_name: "plan", state_name: "plan.md")
    folder = File.join(dir, ".hive-state", "stages", "3-plan", "dispatch-test")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      project_root: dir,
      folder: folder,
      state_file: File.join(folder, state_name),
      stage_name: stage_name,
      slug: "dispatch-test"
    )
  end

  def claude_profile(cfg)
    Hive::AgentProfiles.lookup(:claude, cfg: cfg)
  end

  def codex_profile(cfg)
    Hive::AgentProfiles.lookup(:codex, cfg: cfg)
  end

  def test_plan_uses_claude_launcher_for_claude_profile
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir)
      with_spawn_capture do |captured|
        Hive::Stages::Plan.spawn_plan_agent(task, cfg, "prompt", claude_profile(cfg))

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "hive-3-plan-dispatch-test", captured[0][:kwargs][:session_name]
      end
    end
  end

  def test_brainstorm_headless_claude_mode_still_uses_claude_launcher
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "headless" } }
      task = make_task(dir, stage_name: "brainstorm", state_name: "brainstorm.md")
      File.write(File.join(task.folder, "idea.md"), "test idea")

      with_spawn_capture do |captured|
        Hive::Stages::Brainstorm.run!(task, cfg)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "headless", captured[0][:cfg].dig("claude", "mode")
      end
    end
  end

  def test_brainstorm_legacy_headless_runtime_uses_claude_launcher_in_headless_mode
    with_tmp_dir do |dir|
      cfg = { "brainstorm" => { "runtime" => "headless" } }
      task = make_task(dir, stage_name: "brainstorm", state_name: "brainstorm.md")
      File.write(File.join(task.folder, "idea.md"), "test idea")

      with_spawn_capture do |captured|
        Hive::Stages::Brainstorm.run!(task, cfg)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "headless", captured[0][:cfg].dig("claude", "mode")
      end
    end
  end

  def test_plan_keeps_non_claude_profile_on_headless_spawn
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "agents" => {
          "codex" => { "bin" => "codex" }
        }
      }
      task = make_task(dir)
      with_spawn_capture do |captured|
        Hive::Stages::Plan.spawn_plan_agent(task, cfg, "prompt", codex_profile(cfg))

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
      end
    end
  end

  def test_execute_uses_claude_launcher_for_claude_implementer
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "execute" => { "agent" => "claude" }
      }
      task = make_task(dir, stage_name: "execute", state_name: "task.md")
      File.write(File.join(task.folder, "plan.md"), "## Plan\n")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(task, cfg, worktree_path)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "hive-4-execute-dispatch-test", captured[0][:kwargs][:session_name]
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[0][:kwargs][:allowed_tools]
      end
    end
  end

  def test_execute_keeps_non_claude_implementer_on_headless_spawn
    with_tmp_dir do |dir|
      cfg = {
        "claude" => { "mode" => "tmux" },
        "execute" => { "agent" => "codex" },
        "agents" => {
          "codex" => { "bin" => "codex" }
        }
      }
      task = make_task(dir, stage_name: "execute", state_name: "task.md")
      File.write(File.join(task.folder, "plan.md"), "## Plan\n")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(task, cfg, worktree_path)

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
      end
    end
  end

  def test_open_pr_and_finalize_use_stage_specific_claude_sessions
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir, stage_name: "open-pr", state_name: "pr.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)

      with_spawn_capture do |captured|
        Hive::Stages::OpenPr.spawn_open_pr_agent(task, cfg, "prompt", claude_profile(cfg), worktree_path)
        Hive::Stages::Finalize.spawn_finalize_agent(task, cfg, "prompt", claude_profile(cfg), worktree_path)

        assert_equal [ :claude, :claude ], captured.map { |call| call[:launcher] }
        assert_equal "hive-5-open-pr-dispatch-test", captured[0][:kwargs][:session_name]
        assert_equal "hive-8-finalize-dispatch-test", captured[1][:kwargs][:session_name]
      end
    end
  end

  def test_artifacts_uses_stage_specific_claude_session
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir, stage_name: "artifacts", state_name: "artifact.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      task.define_singleton_method(:worktree_path) { worktree_path }

      with_spawn_capture do |captured|
        Hive::Stages::Artifacts.spawn_artifacts_agent(task, cfg, "prompt", claude_profile(cfg))

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "hive-7-artifacts-dispatch-test", captured[0][:kwargs][:session_name]
      end
    end
  end
end
