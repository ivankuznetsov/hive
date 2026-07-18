require "test_helper"
require "hive/agent_profiles"
require "hive/stages/execute"
require "hive/stages/finalize"
require "hive/stages/open_pr"
require "hive/stages/plan"
require "hive/stages/artifacts"
require "hive/stages/brainstorm"
require "hive/stages/review"
require "hive/stages/review/ci_fix"
require "hive/reviewers"

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
        # G3: plan uses the narrow allowed_tools set (no Bash/Glob/Grep) —
        # planning operates on prose, not the worktree.
        assert_equal "Read,Write,Edit,LS", captured[0][:kwargs][:allowed_tools]
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
      identity = Hive::ImplementationIdentity::Resolver.new(cfg: identity_config).resolve_execute(
        generation: 1, attempt_id: "exec"
      )

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(
          task, cfg, worktree_path, identity: identity
        )

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
        assert_equal [ "--model", "gpt-5.6-sol" ],
                     captured[0][:kwargs][:identity_arguments].first(2)
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
        # G3: open-pr and finalize both need the WIDE allowed_tools set
        # (Bash/Glob/Grep) — they read the worktree and run git/gh.
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[0][:kwargs][:allowed_tools]
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[1][:kwargs][:allowed_tools]
      end
    end
  end

  def test_open_pr_forwards_codex_utility_identity_arguments
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir, stage_name: "open-pr", state_name: "pr.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      identity_cfg = identity_config
      execute = Hive::ImplementationIdentity::Resolver.new(cfg: identity_cfg).resolve_execute(
        generation: 1, attempt_id: "exec"
      )
      identity = Hive::ImplementationIdentity::Resolver.new(cfg: identity_cfg).resolve_stage(
        "open_pr", execute_identity: execute
      )

      with_spawn_capture do |captured|
        Hive::Stages::OpenPr.spawn_open_pr_agent(
          task, cfg, "prompt", codex_profile(cfg), worktree_path, identity: identity
        )

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
        assert_equal [ "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=medium" ],
                     captured[0][:kwargs][:identity_arguments]
      end
    end
  end

  def test_review_fix_forwards_execute_model_with_high_effort
    with_tmp_dir do |dir|
      cfg = identity_config
      task = make_task(dir, stage_name: "review", state_name: "task.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      FileUtils.mkdir_p(File.join(task.folder, "reviews"))
      ctx = Hive::Reviewers::Context.new(
        worktree_path: worktree_path, task_folder: task.folder,
        default_branch: "main", pass: 1
      )
      identity = review_identity(cfg, "review.fix")

      with_spawn_capture do |captured|
        Hive::Stages::Review.spawn_fix_agent(
          task, cfg, ctx, accepted: [], identity: identity
        )

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
        assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high" ],
                     captured[0][:kwargs][:identity_arguments]
      end
    end
  end

  def test_ci_fix_forwards_execute_model_with_high_effort
    with_tmp_dir do |dir|
      cfg = identity_config
      task = make_task(dir, stage_name: "review", state_name: "task.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      FileUtils.mkdir_p(File.join(task.folder, "logs"))
      ctx = Hive::Reviewers::Context.new(
        worktree_path: worktree_path, task_folder: task.folder,
        default_branch: "main", pass: 1
      )
      identity = review_identity(cfg, "review.ci")

      with_spawn_capture do |captured|
        Hive::Stages::Review::CiFix.spawn_fix_agent(
          cfg: cfg, ctx: ctx, command: [ "bin/test" ], attempt: 1,
          max_attempts: 2, captured_output: "failure", identity: identity
        )

        assert_equal :headless, captured.fetch(0).fetch(:launcher)
        assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high" ],
                     captured[0][:kwargs][:identity_arguments]
      end
    end
  end

  def identity_config
    fields = { "agent" => "codex", "model" => "gpt-5.6-sol" }.freeze
    {
      "execute" => fields.dup,
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => fields, "open_pr" => {}, "review.fix" => {}, "review.ci" => {}
      }.freeze
    }
  end

  def review_identity(cfg, stage)
    resolver = Hive::ImplementationIdentity::Resolver.new(cfg: cfg)
    execute = resolver.resolve_execute(generation: 1, attempt_id: "exec")
    resolver.resolve_stage(stage, execute_identity: execute)
  end

  def test_artifacts_uses_stage_specific_claude_session
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir, stage_name: "artifacts", state_name: "artifact.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      task.define_singleton_method(:worktree_path) { worktree_path }

      with_spawn_capture do |captured|
        Hive::Stages::Artifacts.spawn_artifacts_agent(task, cfg, "prompt", claude_profile(cfg),
                                                      screenote: { connected: false })

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "hive-7-artifacts-dispatch-test", captured[0][:kwargs][:session_name]
        # G3: artifacts is on the WIDE allowed_tools set — it inspects
        # the worktree to gather artifact paths.
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[0][:kwargs][:allowed_tools]
      end
    end
  end

  # G3: brainstorm via the new claude-on-tmux path lands the narrow
  # allowed_tools set. A copy-paste regression that widened brainstorm
  # to Bash would extend the prompt-injection blast radius from idea.md
  # to the project worktree — pin the narrow set explicitly.
  def test_brainstorm_claude_tmux_uses_narrow_allowed_tools
    with_tmp_dir do |dir|
      cfg = { "claude" => { "mode" => "tmux" } }
      task = make_task(dir, stage_name: "brainstorm", state_name: "brainstorm.md")
      File.write(File.join(task.folder, "idea.md"), "test idea")

      with_spawn_capture do |captured|
        Hive::Stages::Brainstorm.run!(task, cfg)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_equal "Read,Write,Edit,LS", captured[0][:kwargs][:allowed_tools]
      end
    end
  end
end
