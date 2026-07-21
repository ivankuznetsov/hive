require "test_helper"
require "hive/config"
require "hive/markers"
require "hive/stages/agent"
require "hive/stages/agent_worktree"

class StagesAgentTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :project_root, :folder, :state_file, :stage_name, :slug,
    :stage_index, :log_dir, :project_name, :workflow, :base_branch, :depends_on,
    keyword_init: true
  )

  RaisingProfile = Struct.new(:name, keyword_init: true) do
    def format_skill_invocation(_skill)
      raise "format_skill_invocation should not be called"
    end
  end

  def task_for(project, stage_name, descriptor: Hive::Workflows::Registry.default)
    stage = descriptor.stage_named(stage_name)
    output_file = stage.state_file
    folder = File.join(project, ".hive-state", "stages", stage.dir, "demo-260619-aaaa")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      project_root: project,
      folder: folder,
      state_file: File.join(folder, output_file),
      stage_name: stage_name,
      slug: "demo-260619-aaaa",
      stage_index: 99,
      log_dir: File.join(project, ".hive-state", "logs", "demo-260619-aaaa"),
      project_name: File.basename(project),
      workflow: descriptor
    )
  end

  def with_stubbed_spawn(marker: "<!-- COMPLETE -->\n")
    captured = []
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, prompt:, **kwargs|
      captured << { task: task, prompt: prompt, kwargs: kwargs }
      File.write(task.state_file, marker)
      { status: :ok }
    end
    yield captured
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def with_fixed_user_supplied_tag(tag = "user_supplied_testtag")
    original = Hive::Stages::Base.method(:user_supplied_tag)
    Hive::Stages::Base.define_singleton_method(:user_supplied_tag) { tag }
    yield tag
  ensure
    Hive::Stages::Base.define_singleton_method(:user_supplied_tag, original)
  end

  def test_prompt_wraps_prior_artifacts_and_excludes_own_output
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(File.join(task.folder, "idea.md"), "seed idea\n")
      File.write(File.join(task.folder, "brainstorm.md"), "requirements\n")
      File.write(File.join(task.folder, "plan.md"), "old plan\n")

      with_fixed_user_supplied_tag do |tag|
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

          prompt = captured.first.fetch(:prompt)
          assert_includes prompt, "<#{tag} content_type=\"prior_artifacts\">"
          assert_includes prompt, "</#{tag}>"
          assert_includes prompt, "## brainstorm.md\nrequirements"
          assert_includes prompt, "## idea.md\nseed idea"
          # Prior artifacts are joined in sorted-basename order, so brainstorm.md must
          # precede idea.md. Asserting relative position (not just presence) is what
          # catches a dropped `.sort` in prior_artifacts.
          assert prompt.index("## brainstorm.md") < prompt.index("## idea.md"),
                 "prior artifacts must be ordered by sorted basename (brainstorm before idea)"
          refute_includes prompt, "## plan.md"
          refute_includes prompt, "old plan"
        end
      end
    end
  end

  def test_worktree_stage_delegates_before_generic_agent_spawn
    with_tmp_dir do |project|
      descriptor = worktree_workflow
      task = task_for(project, "fix", descriptor: descriptor)
      delegated = []
      replacement = lambda do |received_task, cfg|
        delegated << [ received_task, cfg ]
        { commit: "worktree_initialized", status: :worktree_ready }
      end

      with_replaced_singleton_method(Hive::Stages::AgentWorktree, :run!, replacement) do
        with_stubbed_spawn do |captured|
          result = Hive::Stages::Agent.run!(task, { "fix" => { "agent" => "codex" } })

          assert_equal({ commit: "worktree_initialized", status: :worktree_ready }, result)
          assert_equal 1, delegated.length
          assert_empty captured
        end
      end
    end
  end

  def test_worktree_setup_creates_exact_receipt_and_resumes_matching_state
    with_draft_pr_task do |task, worktree_root|
      with_fake_github_controller do |auth_calls|
        first = Hive::Stages::AgentWorktree.prepare!(task, {})
        second = Hive::Stages::AgentWorktree.prepare!(task, {})

        assert_equal first, second
        assert_equal File.join(worktree_root, task.slug), first.worktree_path
        assert_equal task.slug, first.task_branch
        assert_equal "master", first.base_branch
        assert_equal "github.com/acme/widgets", first.repository
        assert_equal first.base_oid, run!("git", "-C", first.worktree_path, "rev-parse", "HEAD").strip
        assert_equal 2, auth_calls.length, "every run and resume must re-check controller gh auth"

        pointer = Hive::Worktree.read_strict_pointer(task.folder, expected_root: worktree_root)
        receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: worktree_root)
        assert_equal pointer.fetch("base_oid"), receipt.fetch("base_oid")
        assert_equal pointer.fetch("path"), receipt.fetch("worktree_path")
        assert_equal 0o600, File.stat(File.join(task.folder, "worktree.yml")).mode & 0o777
        assert_equal 0o600, File.stat(File.join(task.folder, "handoff.yml")).mode & 0o777
      end
    end
  end

  def test_worktree_setup_auth_failure_creates_no_worktree
    with_draft_pr_task do |task, worktree_root|
      identity = ->(_path, cfg: nil) { { "host" => "github.com", "repository" => "acme/widgets" } }
      fetch_identity = ->(_path, _cfg) { "github.com/acme/widgets" }
      denied = ->(_cfg = nil, host: nil, timeout_sec: nil) { raise Hive::GhError, "auth denied" }

      with_replaced_singleton_method(Hive::Gh, :repository_identity, identity) do
        with_replaced_singleton_method(Hive::Stages::AgentWorktree, :controller_fetch_repository!, fetch_identity) do
          with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, denied) do
            assert_raises(Hive::GhError) { Hive::Stages::AgentWorktree.prepare!(task, {}) }
          end
        end
      end

      refute File.exist?(File.join(worktree_root, task.slug))
      refute File.exist?(File.join(task.folder, "worktree.yml"))
      refute File.exist?(File.join(task.folder, "handoff.yml"))
    end
  end

  def test_worktree_setup_preserves_incomplete_resume_state_and_blocks
    with_draft_pr_task do |task, worktree_root|
      with_fake_github_controller do
        context = Hive::Stages::AgentWorktree.prepare!(task, {})
        FileUtils.rm_f(File.join(task.folder, "handoff.yml"))

        error = assert_raises(Hive::WorktreeError) do
          Hive::Stages::AgentWorktree.prepare!(task, {})
        end

        assert_includes error.message, "state is incomplete"
        assert File.exist?(File.join(task.folder, "worktree.yml"))
        assert File.directory?(context.worktree_path)
        assert_equal task.slug, run!("git", "-C", context.worktree_path, "branch", "--show-current").strip
        assert_equal File.join(worktree_root, task.slug), context.worktree_path
      end
    end
  end

  def test_worktree_stage_runs_one_configured_agent_in_exact_worktree_and_validates_ready_report
    with_draft_pr_task do |task, _worktree_root|
      File.write(File.join(task.folder, "brief.md"), "Fix the nil response.\n")
      captured = []
      run_command = method(:run!)
      report_source = valid_fix_report
      spawn = lambda do |_task, prompt:, **kwargs|
        captured << { prompt: prompt, kwargs: kwargs }
        File.write(File.join(kwargs.fetch(:cwd), "fix.rb"), "fixed\n")
        run_command.call("git", "-C", kwargs.fetch(:cwd), "add", "fix.rb")
        run_command.call("git", "-C", kwargs.fetch(:cwd), "commit", "-m", "fix nil response", "--quiet")
        File.write(File.join(task.folder, "fix-report.md"), report_source)
        { status: :ok, exit_code: 0 }
      end

      with_fake_github_controller do
        with_fixed_user_supplied_tag do |tag|
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
            result = Hive::Stages::AgentWorktree.run!(
              task, "fix" => { "agent" => "codex" }
            )

            assert_equal :ready, result.fetch(:status)
            assert_equal "agent_validated", result.fetch(:commit)
            assert_equal 1, result.fetch(:repository_state).commit_count
            assert_equal 1, captured.length
            call = captured.first
            assert_equal result.fetch(:worktree_context).worktree_path, call.dig(:kwargs, :cwd)
            assert_equal :exit_code_only, call.dig(:kwargs, :status_mode)
            assert_equal :codex, call.dig(:kwargs, :profile).name
            assert_includes call.fetch(:prompt), File.join(task.folder, "fix-report.md")
            assert_includes call.fetch(:prompt), "<#{tag} content_type=\"prior_artifacts\">"
            assert_includes call.fetch(:prompt), "Fix the nil response."
            assert_includes call.fetch(:prompt), "Do not run `gh`"
            refute_includes call.fetch(:prompt), "<!-- COMPLETE -->"
          end
        end
      end
    end
  end

  def test_worktree_stage_accepts_clean_no_fix_and_ignores_stale_report_on_runtime_error
    with_draft_pr_task do |task, _worktree_root|
      calls = 0
      report_source = valid_fix_report
      spawn = lambda do |_task, **_kwargs|
        calls += 1
        File.write(
          File.join(task.folder, "fix-report.md"),
          report_source.sub("Decision: ready", "Decision: no-fix")
        )
        { status: :ok, exit_code: 0 }
      end
      with_fake_github_controller do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          result = Hive::Stages::AgentWorktree.run!(task, {})
          assert_equal :"no-fix", result.fetch(:status)
          assert_equal 1, calls
        end
      end

      File.write(File.join(task.folder, "fix-report.md"), "Decision: ready\n")
      failed_spawn = ->(_task, **_kwargs) { { status: :error, error_message: "provider quota" } }
      context = Hive::Stages::AgentWorktree::Context.new(
        worktree_path: task.project_root, task_branch: "master", base_branch: "master",
        base_oid: run!("git", "-C", task.project_root, "rev-parse", "HEAD").strip,
        repository: "github.com/acme/widgets"
      )
      with_replaced_singleton_method(Hive::Stages::AgentWorktree, :prepare!, ->(_task, _cfg) { context }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, failed_spawn) do
          result = Hive::Stages::AgentWorktree.run!(task, {})
          assert_equal :error, result.fetch(:status)
          assert_equal "provider quota", result.fetch(:error_message)
          refute File.exist?(File.join(task.folder, "fix-report.md")),
                 "a stale report must be removed before a failed fresh spawn"
        end
      end


      with_replaced_singleton_method(Hive::Stages::AgentWorktree, :prepare!, ->(_task, _cfg) { context }) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :spawn_agent,
          ->(_task, **_kwargs) { { status: :timeout, timed_out: true } }
        ) do
          result = Hive::Stages::AgentWorktree.run!(task, {})
          assert_equal :timeout, result.fetch(:status)
          refute result.key?(:report)
        end
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(_task, **_kwargs) { nil }) do
          result = Hive::Stages::AgentWorktree.run!(task, {})
          assert_equal :error, result.fetch(:status)
        end
        with_replaced_singleton_method(
          Hive::Stages::Base, :spawn_agent,
          ->(_task, **_kwargs) { raise IOError, "stream failed" }
        ) do
          error = assert_raises(IOError) { Hive::Stages::AgentWorktree.run!(task, {}) }
          assert_equal "stream failed", error.message
        end
      end
    end
  end

  def test_worktree_stage_rejects_protected_state_mutation_and_agent_marker_authorship
    %w[meta.yml task.md].each do |protected_name|
      with_draft_pr_task do |task, _worktree_root|
        run_command = method(:run!)
        report_source = valid_fix_report
        spawn = lambda do |_task, **kwargs|
          File.write(File.join(task.folder, protected_name), "agent-owned\n")
          File.write(File.join(kwargs.fetch(:cwd), "fix.rb"), "fixed\n")
          run_command.call("git", "-C", kwargs.fetch(:cwd), "add", "fix.rb")
          run_command.call("git", "-C", kwargs.fetch(:cwd), "commit", "-m", "fix", "--quiet")
          File.write(File.join(task.folder, "fix-report.md"), report_source)
          { status: :ok, exit_code: 0 }
        end

        with_fake_github_controller do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
            error = assert_raises(Hive::StageError) do
              Hive::Stages::AgentWorktree.run!(task, {})
            end
            assert_includes error.message, protected_name
          end
        end
      end
    end
  end

  def test_worktree_stage_protects_controller_handoff_files_without_changing_global_stage_ownership
    expected = Hive::ProtectedFiles::ORCHESTRATOR_OWNED + %w[meta.yml handoff.yml pr.md]

    assert_equal expected, Hive::Stages::AgentWorktree::PROTECTED_FILES
    refute_includes Hive::ProtectedFiles::ORCHESTRATOR_OWNED, "pr.md"
  end

  def test_worktree_stage_rejects_symlinked_report
    with_draft_pr_task do |task, _worktree_root|
      report_source = valid_fix_report
      spawn = lambda do |_task, **_kwargs|
        target = File.join(task.folder, "outside-report.md")
        File.write(target, report_source)
        File.symlink(target, File.join(task.folder, "fix-report.md"))
        { status: :ok, exit_code: 0 }
      end

      with_fake_github_controller do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          error = assert_raises(Hive::StageError) do
            Hive::Stages::AgentWorktree.run!(task, {})
          end
          assert_includes error.message, "not a symlink"
        end
      end
    end
  end

  def test_worktree_stage_checks_protected_files_when_spawn_raises
    with_draft_pr_task do |task, _worktree_root|
      spawn = lambda do |_task, **_kwargs|
        File.write(File.join(task.folder, "pr.md"), "forged\n")
        raise IOError, "stream failed"
      end

      with_fake_github_controller do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          error = assert_raises(Hive::StageError) do
            Hive::Stages::AgentWorktree.run!(task, {})
          end
          assert_includes error.message, "pr.md"
          refute_includes error.message, "stream failed"
        end
      end
    end
  end

  def test_worktree_stage_rejects_preexisting_symlinked_controller_file_before_spawn
    with_tmp_dir do |project|
      task = task_for(project, "fix", descriptor: worktree_workflow)
      target = File.join(project, "outside-meta.yml")
      File.write(target, "id: 1\n")
      File.symlink(target, File.join(task.folder, "meta.yml"))
      context = Hive::Stages::AgentWorktree::Context.new(
        worktree_path: project, task_branch: task.slug, base_branch: "main",
        base_oid: "a" * 40, repository: "github.com/acme/widgets"
      )
      calls = 0

      with_replaced_singleton_method(Hive::Stages::AgentWorktree, :prepare!, ->(_task, _cfg) { context }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { calls += 1 }) do
          error = assert_raises(Hive::StageError) do
            Hive::Stages::AgentWorktree.run!(task, {})
          end
          assert_includes error.message, "meta.yml"
        end
      end
      assert_equal 0, calls
      assert_equal "id: 1\n", File.read(target)
    end
  end

  def test_worktree_prompt_includes_bounded_package_instruction
    with_tmp_dir do |project|
      instruction = File.join(project, "fix-instruction.md")
      File.write(instruction, "Use the local reproducer before editing.\n")
      descriptor = worktree_workflow(instruction: instruction)
      task = task_for(project, "fix", descriptor: descriptor)
      context = Hive::Stages::AgentWorktree::Context.new(
        worktree_path: project, task_branch: task.slug, base_branch: "main",
        base_oid: "a" * 40, repository: "github.com/acme/widgets"
      )

      prompt = Hive::Stages::AgentWorktree.render_prompt(
        task, descriptor.stage_named("fix"), context,
        File.join(task.folder, "fix-report.md")
      )
      assert_includes prompt, "Use the local reproducer before editing."

      File.write(instruction, "x" * (Hive::Stages::AgentWorktree::MAX_INSTRUCTION_CHARS + 1))
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentWorktree.render_prompt(
          task, descriptor.stage_named("fix"), context,
          File.join(task.folder, "fix-report.md")
        )
      end
      FileUtils.rm_f(instruction)
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentWorktree.render_prompt(
          task, descriptor.stage_named("fix"), context,
          File.join(task.folder, "fix-report.md")
        )
      end
    end
  end

  def test_worktree_stage_rejects_noncanonical_report_path_before_spawn
    with_tmp_dir do |project|
      descriptor = worktree_workflow(deliverable: "report.md")
      task = task_for(project, "fix", descriptor: descriptor)
      context = Hive::Stages::AgentWorktree::Context.new(
        worktree_path: project, task_branch: task.slug, base_branch: "main",
        base_oid: "a" * 40, repository: "github.com/acme/widgets"
      )
      calls = 0
      with_replaced_singleton_method(Hive::Stages::AgentWorktree, :prepare!, ->(_task, _cfg) { context }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { calls += 1 }) do
          assert_raises(Hive::StageError) do
            Hive::Stages::AgentWorktree.run!(task, {})
          end
        end
      end
      assert_equal 0, calls
    end
  end

  def test_prior_artifacts_capped_at_8000_chars
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(File.join(task.folder, "huge.md"), "x" * 20_000)

      prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")

      assert_equal 8000, prior.length,
                   "prior_artifacts must cap the joined string at 8000 chars"
    end
  end

  def test_prior_artifacts_cap_applies_to_joined_multi_file_string
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      # Two under-cap files whose joined length (headers + 5k + 5k + separator)
      # exceeds 8000: proves the cap is on the joined string, not per file.
      File.write(File.join(task.folder, "a.md"), "a" * 5000)
      File.write(File.join(task.folder, "b.md"), "b" * 5000)

      prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")

      assert_equal 8000, prior.length,
                   "the 8000-char cap must apply to the joined multi-file string, not per file"
      assert prior.start_with?("## a.md\n"),
             "the joined string must begin with the first sorted file before truncation"
    end
  end

  def test_prior_artifacts_degrades_unreadable_sibling
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      path = File.join(task.folder, "gone.md")
      File.write(path, "vanishing")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::ENOENT, "gone" if candidate == path

        original.call(candidate, *args, **kwargs)
      }) do
        prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")
        assert_includes prior, "## gone.md\n(unreadable: Errno::ENOENT)"
      end
    end
  end

  def test_run_raises_stage_error_when_stage_absent_from_registry
    with_tmp_dir do |project|
      folder = File.join(project, ".hive-state", "stages", "99-mystery", "demo-260619-aaaa")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        project_root: project,
        folder: folder,
        state_file: File.join(folder, "mystery.md"),
        stage_name: "mystery",
        slug: "demo-260619-aaaa",
        stage_index: 99,
        log_dir: File.join(project, ".hive-state", "logs", "demo-260619-aaaa"),
        project_name: File.basename(project),
        workflow: Hive::Workflows::Registry.default
      )

      error = assert_raises(Hive::StageError) do
        Hive::Stages::Agent.run!(task, {})
      end

      assert_equal "no agent stage mystery", error.message
    end
  end

  def test_empty_prior_artifacts_render_without_error
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_fixed_user_supplied_tag do |tag|
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

          prompt = captured.first.fetch(:prompt)
          assert_includes prompt, "<#{tag} content_type=\"prior_artifacts\">\n\n</#{tag}>"
        end
      end
    end
  end

  def test_skill_present_uses_profile_formatted_invocation
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "brainstorm" => { "agent" => "pi" } })

        assert_includes captured.first.fetch(:prompt), "Use the /skill:ce-brainstorm skill"
        assert_equal :pi, captured.first.fetch(:kwargs).fetch(:profile).name
      end
    end
  end

  def test_skill_absent_uses_generic_instruction_without_formatting
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      profile = RaisingProfile.new(name: :no_skill)

      with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage_name, **_kwargs) { profile }) do
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, {})

          assert_includes captured.first.fetch(:prompt), "Write `plan.md` - produce the best `plan` you can."
          assert_same profile, captured.first.fetch(:kwargs).fetch(:profile)
        end
      end
    end
  end

  def test_instruction_backed_stage_uses_instruction_body_without_skill_or_generic_fallback
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Write a concise implementation note.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      File.write(File.join(task.folder, "idea.md"), "prior idea\n")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        prompt = captured.first.fetch(:prompt)
        assert_includes prompt, "Write a concise implementation note."
        assert_includes prompt, "## idea.md\nprior idea"
        refute_includes prompt, "Use the"
        refute_includes prompt, "produce the best `work`"
      end
    end
  end

  def test_descriptor_permissions_override_config_permission_spec
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do scoped work.\n")
      descriptor = instruction_workflow(instruction_path, permissions: "read-only")
      task = task_for(project, "work", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "permissions" => "yolo" })

        kwargs = captured.first.fetch(:kwargs)
        assert_equal "default", kwargs.fetch(:permission_mode)
        assert_equal %w[Read LS Grep Glob], kwargs.fetch(:allowed_tools)
        assert_equal %w[Write Edit MultiEdit NotebookEdit Bash], kwargs.fetch(:disallowed_tools)
      end
    end
  end

  def test_managed_actor_reuses_one_runtime_context_for_prompt_and_permissions
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      package_root = File.join(project, ".hive-state", "workflows", "demo", "versions", "#{'a' * 40}")
      File.write(instruction_path, "Do managed work.\n")
      FileUtils.mkdir_p(package_root)
      descriptor = instruction_workflow(instruction_path, permissions: "read-only")
      task = task_for(project, "work", descriptor: descriptor)
      context = { package_root: package_root, environment: { "DEMO_INPUT" => "configured" } }
      loads = 0
      task.define_singleton_method(:managed_workflow?) { true }
      task.define_singleton_method(:managed_runtime_context) do |slot_id|
        loads += 1
        raise "wrong managed slot" unless slot_id == "stages.work"

        context
      end
      task.define_singleton_method(:managed_prompt) do |slot_id, body, supplied_context|
        raise "wrong managed context" unless supplied_context.equal?(context)

        "#{slot_id}:#{body}"
      end

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        assert_equal 1, loads
        assert_match(/\Astages\.work:/, captured.first.fetch(:prompt))
        policy = captured.first.fetch(:kwargs).fetch(:runtime_policy)
        assert_equal "configured", policy.environment.fetch("DEMO_INPUT")
      end
    end
  end

  def test_descriptor_permissions_fail_closed_when_runner_cannot_enforce_scope
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do scoped work.\n")
      descriptor = instruction_workflow(instruction_path, permissions: "read-only")
      task = task_for(project, "work", descriptor: descriptor)

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Agent.run!(task, { "work" => { "agent" => "codex" } })
      end

      marker = Hive::Markers.current(task.state_file)
      assert_match(/cannot enforce tool scoping/, error.message)
      assert_equal :error, marker.name
      assert_equal "permission_config_error", marker.attrs.fetch("reason")
    end
  end

  def test_spawn_uses_task_folder_state_marker_mode_cfg_and_descriptor_defaults
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        cfg = { "brainstorm" => { "agent" => "codex" } }
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal [ task.folder ], kwargs.fetch(:add_dirs)
        assert_equal task.folder, kwargs.fetch(:cwd)
        assert_equal :state_file_marker, kwargs.fetch(:status_mode)
        assert_same cfg, kwargs.fetch(:cfg)
        assert_equal 50, kwargs.fetch(:max_budget_usd)
        assert_equal 1800, kwargs.fetch(:timeout_sec)
        assert_equal "brainstorm", kwargs.fetch(:log_label)
      end
    end
  end

  def test_spawn_uses_plan_descriptor_budget_and_timeout_defaults
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 100, kwargs.fetch(:max_budget_usd),
                     "plan must fall back to its descriptor budget_usd (100)"
        assert_equal 3600, kwargs.fetch(:timeout_sec),
                     "plan must fall back to its descriptor timeout_sec (3600)"
      end
    end
  end

  def test_spawn_uses_task_workflow_descriptor_for_generic_stage
    with_tmp_dir do |project|
      descriptor = dispatch_workflow
      task = task_for(project, "gather", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 1.0, kwargs.fetch(:max_budget_usd)
        assert_equal 60, kwargs.fetch(:timeout_sec)
        assert_equal "gather", kwargs.fetch(:log_label)
        assert_equal File.join(task.folder, "gather.md"), task.state_file
      end
    end
  end

  def test_descriptor_limits_override_merged_defaults_when_project_does_not_set_them
    with_tmp_dir do |project|
      descriptor = resource_workflow(name: "plan", budget_usd: 1.5, timeout_sec: 60)
      task = task_for(project, "plan", descriptor: descriptor)
      cfg = Hive::Config.load(project)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 1.5, kwargs.fetch(:max_budget_usd)
        assert_equal 60, kwargs.fetch(:timeout_sec)
      end
    end
  end

  def test_explicit_project_limits_override_descriptor_limits_after_config_load
    with_tmp_dir do |project|
      descriptor = resource_workflow(name: "plan", budget_usd: 1.5, timeout_sec: 60)
      task = task_for(project, "plan", descriptor: descriptor)
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        <<~YAML
          budget_usd:
            plan: 2.5
          timeout_sec:
            plan: 90
        YAML
      )
      cfg = Hive::Config.load(project)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 2.5, kwargs.fetch(:max_budget_usd)
        assert_equal 90, kwargs.fetch(:timeout_sec)
      end
    end
  end

  def test_null_project_limits_fall_back_to_descriptor_limits_after_config_load
    with_tmp_dir do |project|
      descriptor = resource_workflow(name: "plan", budget_usd: 1.5, timeout_sec: 60)
      task = task_for(project, "plan", descriptor: descriptor)
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        <<~YAML
          budget_usd:
            plan:
          timeout_sec:
            plan:
        YAML
      )
      cfg = Hive::Config.load(project)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 1.5, kwargs.fetch(:max_budget_usd)
        assert_equal 60, kwargs.fetch(:timeout_sec)
      end
    end
  end

  def test_descriptor_agent_overrides_project_stage_agent
    with_tmp_dir do |project|
      descriptor = instruction_workflow_with_agent(agent: "codex")
      task = task_for(project, "work", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "work" => { "agent" => "pi" } })

        assert_equal :codex, captured.first.fetch(:kwargs).fetch(:profile).name
      end
    end
  end

  def test_descriptor_model_and_effort_are_passed_to_spawn
    with_tmp_dir do |project|
      descriptor = instruction_workflow_with_agent(model: "opus", effort: "high")
      task = task_for(project, "work", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        kwargs = captured.first.fetch(:kwargs)
        assert_equal "opus", kwargs.fetch(:model)
        assert_equal "high", kwargs.fetch(:effort)
      end
    end
  end

  def test_spawn_honors_cfg_budget_and_timeout_overrides
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        cfg = {
          "brainstorm" => { "agent" => "codex" },
          "budget_usd" => { "brainstorm" => 12 },
          "timeout_sec" => { "brainstorm" => 34 }
        }
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 12, kwargs.fetch(:max_budget_usd)
        assert_equal 34, kwargs.fetch(:timeout_sec)
      end
    end
  end

  def test_run_accepts_nil_cfg
    # Exercises the `cfg ||= {}` guard in `run!`: a nil cfg must be coerced to
    # {} and run identically to an empty config.
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_stubbed_spawn do
        assert_equal(
          { commit: "complete", status: :complete },
          Hive::Stages::Agent.run!(task, nil),
          "nil cfg must be coerced to {} and run like an empty config"
        )
      end
    end
  end

  def test_run_stamps_error_marker_when_descriptor_instruction_unreadable
    # A descriptor instruction can be renamed/deleted/chmod'd between parse and
    # run (a normal authoring edit). The stage's OWN instruction going missing is
    # fatal, so the runner must stamp an attributed :error marker and stop —
    # never die with a raw Errno or silently re-classify the row as ready_to_run.
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do the work.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES, candidate if candidate == instruction_path

        original.call(candidate, *args, **kwargs)
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "instruction_unreadable", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "Errno::EACCES"
      end
    end
  end

  def test_run_turns_error_envelope_without_marker_into_error_marker
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        { status: :error, error_message: "profile unavailable" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "agent_preflight_failed", marker.attrs["reason"]
        assert_equal "profile unavailable", marker.attrs["message"]
      end
    end
  end

  def test_run_preserves_provider_limit_error_envelope_as_retryable_quota_marker
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        {
          status: :error,
          error_message: "limits reached for claude: You've hit your session limit"
        }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "limits_reached", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "limits_reached", marker.attrs["reason"]
        assert_equal "claude", marker.attrs["provider"]
        assert_includes marker.attrs["message"], "limits reached for claude"
        assert Time.parse(marker.attrs.fetch("retry_after")) > Time.now.utc
      end
    end
  end

  def test_run_uses_provider_reset_date_from_limit_error_envelope
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      reset_at = Time.now.utc + (7 * 24 * 60 * 60)
      limit_text = "You've hit your usage limit. Try again at #{reset_at.strftime('%b %-d, %Y %-I:%M %p')} UTC."

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        {
          status: :error,
          error_message: "limits reached for codex: usage limit",
          limit_text: limit_text
        }
      }) do
        Hive::Stages::Agent.run!(task, {})

        retry_after = Time.parse(Hive::Markers.current(task.state_file).attrs.fetch("retry_after"))
        assert_operator retry_after, :>, Time.now.utc + (6 * 24 * 60 * 60)
        assert_operator retry_after, :<, Time.now.utc + (8 * 24 * 60 * 60)
      end
    end
  end

  def test_run_preserves_retryable_limit_marker_written_over_stale_marker
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      Hive::Markers.set(task.state_file, :error, reason: "agent_preflight_failed")
      retry_after = (Time.now.utc + 3600).iso8601

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        Hive::Markers.set(
          task.state_file,
          :error,
          reason: "limits_reached",
          message: "limits reached for codex: usage limit",
          retry_after: retry_after
        )
        { status: :error, error_message: "limits reached for codex: usage limit" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "limits_reached", status: :error }, result)
        assert_equal "limits_reached", marker.attrs["reason"]
        assert_equal retry_after, marker.attrs["retry_after"]
      end
    end
  end

  def test_run_does_not_overwrite_quota_marker_written_by_agent
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      retry_after = "2026-07-13T23:00:00Z"

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |spawned_task, **_kwargs|
        Hive::Markers.set(
          spawned_task.state_file, :error,
          reason: "limits_reached",
          message: "limits reached for claude: session limit",
          retry_after: retry_after
        )
        { status: :error, error_message: "limits reached for claude: session limit" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "limits_reached", status: :error }, result)
        assert_equal "limits_reached", marker.attrs["reason"]
        assert_equal retry_after, marker.attrs["retry_after"]
        refute marker.attrs.key?("provider"), "preserving the marker must not synthesize or replace attrs"
      end
    end
  end

  def test_run_does_not_relabel_another_fresh_agent_error_as_preflight_failure
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      Hive::Markers.set(task.state_file, :complete)

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |spawned_task, **_kwargs|
        Hive::Markers.set(spawned_task.state_file, :error, reason: "timeout", timeout_sec: 300)
        { status: :error, error_message: "agent timed out" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "timeout", marker.attrs["reason"]
        assert_equal "300", marker.attrs["timeout_sec"]
      end
    end
  end

  def test_rerun_overwrites_a_stale_complete_marker_when_preflight_fails
    # On a re-run of an already-markered stage, a {status: :error} preflight
    # failure must OVERWRITE the stale :complete rather than leave it in place —
    # otherwise `hive run` exits 0 reporting :complete and the failure is
    # unobservable (NO-SILENT-CAPS). The spawn wrote no marker this run, so
    # clobbering the stale one is correct (this is what dropping the
    # `marker.name == :none` guard buys).
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(task.state_file, "<!-- COMPLETE -->\n")

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        { status: :error, error_message: "version too old" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result,
                     "a preflight failure on re-run must report :error, not the stale :complete")
        assert_equal :error, marker.name
        assert_equal "agent_preflight_failed", marker.attrs["reason"]
      end
    end
  end

  def test_rerun_overwrites_a_stale_marker_when_instruction_unreadable
    # Same NO-SILENT-CAPS guarantee for the instruction-read failure path: a
    # stale :waiting from a prior run must not survive when the stage's own
    # instruction has since become unreadable (the read happens before any
    # spawn, so no agent wrote a marker this run).
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do the work.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      File.write(task.state_file, "<!-- WAITING -->\n")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES, candidate if candidate == instruction_path

        original.call(candidate, *args, **kwargs)
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result,
                     "an unreadable instruction on re-run must report :error, not the stale :waiting")
        assert_equal :error, marker.name
        assert_equal "instruction_unreadable", marker.attrs.fetch("reason")
      end
    end
  end

  def test_marker_actions_map_to_commit_and_status
    {
      "" => [ nil, :none ],
      "<!-- WAITING -->\n" => [ "round_waiting", :waiting ],
      "<!-- COMPLETE -->\n" => [ "complete", :complete ],
      "<!-- ERROR -->\n" => [ "error", :error ],
      "<!-- AGENT_WORKING -->\n" => [ "agent_working", :agent_working ]
    }.each do |marker_text, expected|
      with_tmp_dir do |project|
        task = task_for(project, "plan")

        with_stubbed_spawn(marker: marker_text) do
          assert_equal({ commit: expected.first, status: expected.last }, Hive::Stages::Agent.run!(task, {}))
        end
      end
    end
  end

  def test_constructing_binding_does_not_define_readers_on_the_shared_class
    # Deterministic regression guard for the seed-dependent NameError flake.
    # The old TemplateBindings lazily ran `attr_reader k` on the SHARED class
    # for each passed key, so a shared template that referenced a key some
    # binding omitted (e.g. agent_prompt.md.erb's `instruction_body`) only
    # rendered if a key-bearing binding was constructed earlier in the suite.
    # A unique sentinel key proves construction must NOT mutate the class —
    # order-independent, so this catches a revert regardless of test ordering.
    klass = Hive::Stages::Base::TemplateBindings
    refute klass.method_defined?(:flake_regression_sentinel),
           "precondition: the sentinel reader must not pre-exist on the class"

    klass.new(flake_regression_sentinel: "x")

    refute klass.method_defined?(:flake_regression_sentinel),
           "TemplateBindings.new must not lazily define per-key readers on the shared class"
  end

  def test_shared_template_renders_when_binding_omits_a_referenced_key
    # A binding that omits instruction_body must resolve it to nil and let the
    # shared agent_prompt template (which references it) render without raising.
    bindings = Hive::Stages::Base::TemplateBindings.new(
      stage_name: "execute", output_file: "task.md",
      user_supplied_tag: "U", prior_context: "", skill_invocation: nil
    )

    assert_respond_to bindings, :instruction_body
    assert_nil bindings.instruction_body, "an unset binding key must read as nil"
    assert_kind_of String, Hive::Stages::Base.render("agent_prompt.md.erb", bindings)
  end

  private

    def resource_workflow(name:, budget_usd:, timeout_sec:)
      Hive::Workflow.new(
        id: :resource_limits,
        stages: [
          Hive::Workflow::Stage.new(
            name: name,
            index: 1,
            state_file: "#{name}.md",
            kind: :agent,
            skill: "/#{name}",
            status_mode: :state_file_marker,
            budget_usd: budget_usd,
            timeout_sec: timeout_sec
          )
        ]
      )
    end

    def worktree_workflow(instruction: nil, deliverable: "fix-report.md")
      Hive::Workflow.new(
        id: :worktree_agent,
        stages: [
          Hive::Workflow::Stage.new(
            name: "fix", index: 1, state_file: "fix-report.md", kind: :agent,
            instruction: instruction,
            workspace: :worktree, handoff: :draft_pr, deliverable: deliverable
          )
        ]
      )
    end

    def valid_fix_report
      <<~REPORT
        Decision: ready

        Reproduction:
        Reproduced locally.

        Cause:
        The response mapper discarded nil values.

        Changes:
        Preserve the response key and add a regression test.

        Tests:
        Focused tests pass.

        Risks:
        Low and localized.

        Suggested PR title: Preserve nil response values
      REPORT
    end

    def with_draft_pr_task
      with_tmp_git_repo do |project|
        origin = "#{project}.agent-worktree-origin.git"
        worktree_root = "#{project}.managed-worktrees"
        begin
          run!("git", "clone", "--bare", project, origin)
          run!("git", "-C", project, "remote", "add", "origin", origin)
          FileUtils.mkdir_p(File.join(project, ".hive-state"))
          File.write(
            File.join(project, ".hive-state", "config.yml"),
            { "worktree_root" => worktree_root, "default_branch" => "master" }.to_yaml
          )
          descriptor = worktree_workflow
          task = task_for(project, "fix", descriptor: descriptor)
          task.base_branch = "master"
          task.depends_on = nil
          yield task, worktree_root
        ensure
          FileUtils.rm_rf(worktree_root)
          FileUtils.rm_rf(origin)
        end
      end
    end

    def with_fake_github_controller
      auth_calls = []
      identity = ->(_path, cfg: nil) { { "host" => "github.com", "repository" => "acme/widgets" } }
      authenticated = lambda do |_cfg = nil, host: nil, timeout_sec: nil|
        auth_calls << host
        nil
      end
      fetch_identity = ->(_path, _cfg) { "github.com/acme/widgets" }
      with_replaced_singleton_method(Hive::Gh, :repository_identity, identity) do
        with_replaced_singleton_method(Hive::Stages::AgentWorktree, :controller_fetch_repository!, fetch_identity) do
          with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, authenticated) do
            yield auth_calls
          end
        end
      end
    end

    def instruction_workflow(instruction_path, permissions: nil)
      Hive::Workflow.new(
        id: :instruction,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: "work",
            index: 2,
            state_file: "work.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "work"),
            kind: :agent,
            instruction: instruction_path,
            permissions: permissions
          )
        ]
      )
    end

    def instruction_workflow_with_agent(agent: nil, model: nil, effort: nil)
      Hive::Workflow.new(
        id: :instruction,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: "work",
            index: 2,
            state_file: "work.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "work"),
            kind: :agent,
            skill: "/ship",
            agent: agent,
            model: model,
            effort: effort
          )
        ]
      )
    end
end
