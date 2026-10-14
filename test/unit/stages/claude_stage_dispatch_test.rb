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

class ClaudeStageDispatchTest < Minitest::Test
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
      cfg = {}
      task = make_task(dir)
      with_spawn_capture do |captured|
        Hive::Stages::Plan.spawn_plan_agent(task, cfg, "prompt", claude_profile(cfg))

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        refute captured[0][:kwargs].key?(:session_name)
        # G3: plan uses the narrow allowed_tools set (no Bash/Glob/Grep) —
        # planning operates on prose, not the worktree.
        assert_equal "Read,Write,Edit,LS", captured[0][:kwargs][:allowed_tools]
      end
    end
  end

  def test_plan_adds_the_execution_base_checkout_to_the_planner_dirs
    with_tmp_dir do |dir|
      cfg = {}
      task = make_task(dir)
      with_spawn_capture do |captured|
        Hive::Stages::Plan.spawn_plan_agent(
          task, cfg, "prompt", claude_profile(cfg), source_checkout: "/tmp/base-checkout"
        )

        assert_includes captured.fetch(0).fetch(:kwargs).fetch(:add_dirs), "/tmp/base-checkout"
      end
    end
  end

  def test_brainstorm_claude_uses_claude_launcher_with_caller_cfg
    with_tmp_dir do |dir|
      cfg = { "claude" => { "permission_mode" => "auto" } }
      task = make_task(dir, stage_name: "brainstorm", state_name: "brainstorm.md")
      File.write(File.join(task.folder, "idea.md"), "test idea")

      with_spawn_capture do |captured|
        Hive::Stages::Brainstorm.run!(task, cfg)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        assert_same cfg, captured[0][:cfg]
      end
    end
  end

  def test_plan_keeps_non_claude_profile_on_headless_spawn
    with_tmp_dir do |dir|
      cfg = {
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

  def test_independent_core_stages_forward_their_exact_routes
    with_tmp_dir do |dir|
      cfg = {
        "brainstorm" => { "agent" => "codex" },
        "plan" => { "agent" => "codex" },
        "artifacts" => { "agent" => "codex" },
        "finalize" => { "agent" => "codex" },
        "models" => %w[brainstorm plan artifacts finalize].to_h do |stage|
          [
            stage,
            { "model" => "model-#{stage}", "effort" => "xhigh" }
          ]
        end
      }
      profile = codex_profile(cfg)
      task = make_task(dir)
      File.write(File.join(task.folder, "idea.md"), "test idea")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      task.define_singleton_method(:worktree_path) { worktree_path }

      with_spawn_capture do |captured|
        Hive::Stages::Brainstorm.run_headless!(task, cfg, profile: profile)
        Hive::Stages::Plan.spawn_plan_agent(task, cfg, "prompt", profile)
        Hive::Stages::Finalize.spawn_finalize_agent(
          task, cfg, "prompt", profile, worktree_path
        )

        assert_equal %w[brainstorm plan finalize],
                     captured.map { |call| call[:kwargs].fetch(:routing_arguments).stage }
        captured.each do |call|
          routing = call[:kwargs].fetch(:routing_arguments)
          assert_equal [
            "--model", "model-#{routing.stage}",
            "-c", "model_reasoning_effort=xhigh"
          ], routing.global_arguments
        end
      end
    end
  end

  def test_execute_uses_claude_launcher_for_claude_implementer
    with_tmp_dir do |dir|
      cfg = {
        "execute" => { "agent" => "claude" }
      }
      task = make_task(dir, stage_name: "execute", state_name: "task.md")
      File.write(File.join(task.folder, "plan.md"), "## Plan\n")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(task, cfg, worktree_path)

        assert_equal :claude, captured.fetch(0).fetch(:launcher)
        refute captured[0][:kwargs].key?(:session_name)
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[0][:kwargs][:allowed_tools]
      end
    end
  end

  def test_execute_keeps_non_claude_implementer_on_headless_spawn
    with_tmp_dir do |dir|
      cfg = {
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

  def test_execute_forwards_routed_codex_arguments
    with_tmp_dir do |dir|
      cfg = routed_identity_config(provider: "codex", stage: "execute_implementation")
      task = make_task(dir, stage_name: "execute", state_name: "task.md")
      File.write(File.join(task.folder, "plan.md"), "## Plan\n")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      identity = Hive::ImplementationIdentity::Resolver.new(cfg: cfg).resolve_execute(
        generation: 1, attempt_id: "exec"
      )

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(
          task, cfg, worktree_path, identity: identity
        )

        kwargs = captured.fetch(0).fetch(:kwargs)
        assert_empty kwargs.fetch(:identity_arguments)
        assert_equal [ "--model", "routed-model", "-c", "model_reasoning_effort=xhigh" ],
                     kwargs.fetch(:routing_arguments).global_arguments
      end
    end
  end

  def test_execute_forwards_routed_claude_arguments_to_claude_launcher
    with_tmp_dir do |dir|
      cfg = routed_identity_config(provider: "claude", stage: "execute_implementation")
      task = make_task(dir, stage_name: "execute", state_name: "task.md")
      File.write(File.join(task.folder, "plan.md"), "## Plan\n")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      identity = Hive::ImplementationIdentity::Resolver.new(cfg: cfg).resolve_execute(
        generation: 1, attempt_id: "exec"
      )

      with_spawn_capture do |captured|
        Hive::Stages::Execute.spawn_implementation(
          task, cfg, worktree_path, identity: identity
        )

        kwargs = captured.fetch(0).fetch(:kwargs)
        assert_empty kwargs.fetch(:identity_arguments)
        assert_equal [ "--model", "routed-model", "--effort", "xhigh" ],
                     kwargs.fetch(:routing_arguments).subcommand_arguments
      end
    end
  end

  def test_open_pr_and_finalize_use_claude_launcher_with_wide_tools
    with_tmp_dir do |dir|
      cfg = {}
      task = make_task(dir, stage_name: "open-pr", state_name: "pr.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)

      with_spawn_capture do |captured|
        Hive::Stages::OpenPr.spawn_open_pr_agent(task, cfg, "prompt", claude_profile(cfg), worktree_path)
        Hive::Stages::Finalize.spawn_finalize_agent(task, cfg, "prompt", claude_profile(cfg), worktree_path)

        assert_equal [ :claude, :claude ], captured.map { |call| call[:launcher] }
        refute captured[0][:kwargs].key?(:session_name)
        refute captured[1][:kwargs].key?(:session_name)
        # G3: open-pr and finalize both need the WIDE allowed_tools set
        # (Bash/Glob/Grep) — they read the worktree and run git/gh.
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[0][:kwargs][:allowed_tools]
        assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured[1][:kwargs][:allowed_tools]
      end
    end
  end

  def test_open_pr_forwards_codex_utility_identity_arguments
    with_tmp_dir do |dir|
      cfg = {}
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

  def test_open_pr_forwards_routed_codex_arguments
    with_tmp_dir do |dir|
      cfg = routed_identity_config(provider: "codex", stage: "open_pr")
      task = make_task(dir, stage_name: "open-pr", state_name: "pr.md")
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      identity = review_identity(cfg, "open_pr")

      with_spawn_capture do |captured|
        Hive::Stages::OpenPr.spawn_open_pr_agent(
          task, cfg, "prompt", codex_profile(cfg), worktree_path, identity: identity
        )

        kwargs = captured.fetch(0).fetch(:kwargs)
        assert_empty kwargs.fetch(:identity_arguments)
        assert_equal [ "--model", "routed-model", "-c", "model_reasoning_effort=xhigh" ],
                     kwargs.fetch(:routing_arguments).global_arguments
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

  def test_review_fix_forwards_routed_codex_arguments
    with_tmp_dir do |dir|
      cfg = routed_identity_config(provider: "codex", stage: "review_fix")
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

        kwargs = captured.fetch(0).fetch(:kwargs)
        assert_empty kwargs.fetch(:identity_arguments)
        assert_equal [ "--model", "routed-model", "-c", "model_reasoning_effort=xhigh" ],
                     kwargs.fetch(:routing_arguments).global_arguments
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

  def test_ci_fix_forwards_routed_codex_arguments
    with_tmp_dir do |dir|
      cfg = routed_identity_config(provider: "codex", stage: "review_ci")
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

        kwargs = captured.fetch(0).fetch(:kwargs)
        assert_empty kwargs.fetch(:identity_arguments)
        assert_equal [ "--model", "routed-model", "-c", "model_reasoning_effort=xhigh" ],
                     kwargs.fetch(:routing_arguments).global_arguments
      end
    end
  end

  # Every Claude stage launch with the default config reaches the headless
  # `claude -p` spawn through ClaudeLauncher (no stub on spawn_claude!).
  def test_default_config_claude_stage_launches_reach_headless_spawn_agent
    with_tmp_dir do |dir|
      cfg = {}
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      captured = []
      spawn = lambda do |_task, **kwargs|
        captured << kwargs
        { status: :ok }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        plan_task = make_task(dir)
        Hive::Stages::Plan.spawn_plan_agent(plan_task, cfg, "prompt", claude_profile(cfg))

        brainstorm_task = make_task(dir, stage_name: "brainstorm", state_name: "brainstorm.md")
        File.write(File.join(brainstorm_task.folder, "idea.md"), "test idea")
        Hive::Stages::Brainstorm.run!(brainstorm_task, cfg)

        execute_task = make_task(dir, stage_name: "execute", state_name: "task.md")
        File.write(File.join(execute_task.folder, "plan.md"), "## Plan\n")
        Hive::Stages::Execute.spawn_implementation(execute_task, cfg, worktree_path)

        Hive::Stages::OpenPr.spawn_open_pr_agent(plan_task, cfg, "prompt", claude_profile(cfg), worktree_path)
        Hive::Stages::Finalize.spawn_finalize_agent(plan_task, cfg, "prompt", claude_profile(cfg), worktree_path)

        review_task = make_task(dir, stage_name: "review", state_name: "task.md")
        FileUtils.mkdir_p(File.join(review_task.folder, "reviews"))
        FileUtils.mkdir_p(File.join(review_task.folder, "logs"))
        ctx = Hive::Reviewers::Context.new(
          worktree_path: worktree_path, task_folder: review_task.folder,
          default_branch: "main", pass: 1
        )
        Hive::Stages::Review.spawn_fix_agent(review_task, cfg, ctx, accepted: [])
        Hive::Stages::Review::CiFix.spawn_fix_agent(
          cfg: cfg, ctx: ctx, command: [ "bin/test" ], attempt: 1,
          max_attempts: 2, captured_output: "failure"
        )
      end

      assert_equal 7, captured.length
      captured.each do |kwargs|
        assert_equal :claude, kwargs.fetch(:profile).name
        refute kwargs.key?(:session_name)
      end
      assert_equal %w[plan brainstorm execute-impl open-pr-author finalize review-fix-pass01],
                   captured.first(6).map { |kwargs| kwargs.fetch(:log_label) }
      # Yolo (the default scope) keeps each stage's default --allowedTools.
      assert_equal "Read,Write,Edit,LS", captured.fetch(0).fetch(:allowed_tools)
      assert_equal "Read,Write,Edit,Bash,LS,Glob,Grep", captured.fetch(2).fetch(:allowed_tools)
    end
  end

  # A headless Claude launch that raises AgentError in plan lands the
  # `claude_launch_failed` marker on the plan's own state file and returns
  # an error envelope instead of escaping as a crash (daemon auto-retry
  # keys on that reason).
  def test_plan_claude_launch_failure_writes_claude_launch_failed_marker
    with_tmp_dir do |dir|
      cfg = {}
      task = make_task(dir)
      File.write(task.state_file, "<!-- AGENT_WORKING -->\n")
      spawn = ->(_task, **_kwargs) { raise Hive::AgentError, "claude binary not runnable" }

      result = nil
      _out, err = capture_io do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          result = Hive::Stages::Plan.spawn_plan_agent(task, cfg, "prompt", claude_profile(cfg))
        end
      end

      assert_equal({ status: :error, error_message: "claude binary not runnable" }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "claude_launch_failed", marker.attrs["reason"]
      assert_equal "Hive::AgentError", marker.attrs["exception_class"]
      assert_includes marker.attrs["message"], "claude binary not runnable"
      assert_includes err, "claude launch failed"
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

  def routed_identity_config(provider:, stage:)
    fields = { "agent" => provider }.freeze
    models = {
      "execute_implementation" => { "model" => "routed-execute-model" }
    }
    models[stage] = { "model" => "routed-model", "effort" => "xhigh" }
    {
      "execute" => fields.dup,
      "models" => models,
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


  # G3: brainstorm via the Claude launcher lands the narrow
  # allowed_tools set. A copy-paste regression that widened brainstorm
  # to Bash would extend the prompt-injection blast radius from idea.md
  # to the project worktree — pin the narrow set explicitly.
  def test_brainstorm_claude_uses_narrow_allowed_tools
    with_tmp_dir do |dir|
      cfg = {}
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
