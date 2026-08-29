require "test_helper"
require "hive/plan_review/planner_revision"

class PlanReviewPlannerRevisionTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :project_root, keyword_init: true)
  RunnerTask = Struct.new(:folder, :meta_yml_path, keyword_init: true)

  def test_accepts_one_complete_candidate_and_leaves_input_plan_untouched
    Dir.mktmpdir("hive-plan-revision") do |root|
      initialize_repository(root)
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      canonical = File.join(task_folder, "plan.md")
      File.write(canonical, "# Original\n<!-- COMPLETE -->\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- COMPLETE -->\n")
        { "status" => "success", "actual_route" => planner_identity }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder, project_root: root), cfg: {}, runner:
      )

      result = service.call(
        review_id: "pr-#{'a' * 64}", plan_bytes: File.binread(canonical), findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert result.success?
      assert_equal "# Revised\n<!-- COMPLETE -->\n", result.candidate_bytes
      assert_equal "# Original\n<!-- COMPLETE -->\n", File.binread(canonical)
    end
  end

  def test_rejects_waiting_candidate
    Dir.mktmpdir("hive-plan-revision") do |root|
      initialize_repository(root)
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- WAITING -->\n")
        { "status" => "success" }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder, project_root: root), cfg: {}, runner:
      )
      result = service.call(
        review_id: "pr-#{'b' * 64}", plan_bytes: "# Plan\n", findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert_equal "terminal_failure", result.outcome
      assert_match(/COMPLETE/, result.diagnostic)
    end
  end

  def test_rejects_candidate_before_allocating_more_than_the_byte_limit
    Dir.mktmpdir("hive-plan-revision") do |root|
      initialize_repository(root)
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      runner = lambda do |output_path:, **|
        File.binwrite(
          output_path,
          "a" * (Hive::PlanReview::PlannerRevision::MAX_CANDIDATE_BYTES + 1)
        )
        { "status" => "success" }
      end
      result = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder, project_root: root), cfg: {}, runner:
      ).call(
        review_id: "pr-#{'c' * 64}", plan_bytes: "# Plan\n", findings: [],
        planner_identity:, timeout_sec: 60
      )

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "size limit"
    end
  end

  def test_production_runner_confines_revision_and_normalizes_provider_route_errors
    Dir.mktmpdir("hive-plan-revision-runner") do |root|
      meta = File.join(root, "meta.yml")
      File.write(meta, "id: demo\n")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      input = File.join(workspace, "input-plan.md")
      output = File.join(workspace, "candidate-output.md")
      File.write(input, "# Plan\n")
      task = RunnerTask.new(folder: root, meta_yml_path: meta)
      runner = Hive::PlanReview::PlannerRevision::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      identity = planner_identity.merge("provider" => "codex")
      launch = nil
      replacement = lambda do |_task, **kwargs|
        launch = kwargs
        raise Hive::ProviderRouteFailed, "route failed"
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        observed = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity: identity, timeout_sec: 60
        )
      end

      assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                   launch.fetch(:permission_mode)
      assert_equal "retryable_failure", observed.fetch("status")
      assert_equal identity, observed.fetch("actual_route")
    end
  end

  def test_default_planner_identity_uses_the_provider_default_without_a_foreign_model_flag
    runner = Hive::PlanReview::PlannerRevision::HiveRunner.allocate
    profile = Hive::AgentProfiles.lookup(:codex)
    identity = {
      "provider" => "codex", "model" => "default", "family" => "openai",
      "effort" => "default", "route" => "codex-cli/v1"
    }

    arguments = runner.send(:launch_arguments, profile, identity)

    assert_equal({ cli_flags: [] }, arguments)
  end

  def test_production_runner_reports_tampering_missing_output_success_and_firewall_errors
    Dir.mktmpdir("hive-plan-revision-runner-branches") do |root|
      meta = File.join(root, "meta.yml")
      File.write(meta, "id: demo\n")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "input-plan.md"), "# Plan\n")
      output = File.join(workspace, "candidate-output.md")
      task = RunnerTask.new(folder: root, meta_yml_path: meta)
      runner = Hive::PlanReview::PlannerRevision::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )

      tamper = lambda do |_task, agent_custody:, **kwargs|
        agent_custody.call do
          File.write(meta, "changed: true\n")
          File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
          { status: :ok, usage: { model: "served-model" } }
        end
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, tamper) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "terminal_failure", result.fetch("status")
        assert_includes result.fetch("diagnostic"), "protected artifacts"
      end

      FileUtils.rm_f(output)
      missing = lambda do |_task, agent_custody:, **|
        agent_custody.call { { status: :failed, error_message: "no candidate" } }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, missing) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "retryable_failure", result.fetch("status")
        assert_equal "no candidate", result.fetch("diagnostic")
      end

      success = lambda do |_task, agent_custody:, **kwargs|
        agent_custody.call do
          File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
          { status: :ok, usage: { model: "served-model" } }
        end
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, success) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "success", result.fetch("status")
        assert_equal "served-model", result.dig("actual_route", "model")
      end

      timed_out_complete = lambda do |_task, agent_custody:, **kwargs|
        agent_custody.call do
          File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
          { status: :timeout, timed_out: true }
        end
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, timed_out_complete) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "success", result.fetch("status")
        assert_includes result.fetch("diagnostic"), "salvaged complete candidate"
      end

      malformed_telemetry_complete = lambda do |_task, agent_custody:, **kwargs|
        agent_custody.call do
          File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
          {
            status: :failed,
            error_reason: "malformed_output",
            error_message: "OpenCode sanitized export is malformed: unexpected EOF"
          }
        end
      end
      with_replaced_singleton_method(
        Hive::Stages::Base, :spawn_agent, malformed_telemetry_complete
      ) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "success", result.fetch("status")
        assert_includes result.fetch("diagnostic"), "planner telemetry failure"
      end

      capture_error = ->(_manifest) { raise Hive::ArtifactFirewall::Error, "capture failed" }
      with_replaced_singleton_method(Hive::ArtifactFirewall, :capture, capture_error) do
        invoke_custody = lambda do |_task, agent_custody:, **|
          agent_custody.call { flunk "provider must not run after custody capture fails" }
        end
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, invoke_custody) do
          result = runner.call(
            prompt: "revise", workspace:, output_path: output,
            planner_identity:, timeout_sec: 60
          )
          assert_equal "terminal_failure", result.fetch("status")
          assert_equal "capture failed", result.fetch("diagnostic")
        end
      end
    end
  end

  def test_production_runner_keeps_controller_session_bookkeeping_outside_agent_custody
    Dir.mktmpdir("hive-plan-revision-controller-bookkeeping") do |root|
      meta = File.join(root, "meta.yml")
      journal = File.join(root, "task-journal.jsonl")
      projection = File.join(root, "task-projection.json")
      File.write(meta, "id: demo\n")
      File.write(journal, "before\n")
      File.write(projection, "before\n")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "input-plan.md"), "# Plan\n")
      output = File.join(workspace, "candidate-output.md")
      task = RunnerTask.new(folder: root, meta_yml_path: meta)
      runner = Hive::PlanReview::PlannerRevision::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      spawn = lambda do |_task, agent_custody:, **kwargs|
        File.write(journal, "session-start\n")
        result = agent_custody.call do
          File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
          { status: :ok, usage: { model: "served-model" } }
        end
        File.write(projection, "session-finish\n")
        result
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        observed = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
      end

      assert_equal "success", observed.fetch("status")
      assert_equal "session-start\n", File.read(journal)
      assert_equal "session-finish\n", File.read(projection)
    end
  end

  def test_production_runner_rejects_success_when_spawn_skips_agent_custody
    Dir.mktmpdir("hive-plan-revision-custody-missing") do |root|
      meta = File.join(root, "meta.yml")
      File.write(meta, "id: demo\n")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "input-plan.md"), "# Plan\n")
      output = File.join(workspace, "candidate-output.md")
      task = RunnerTask.new(folder: root, meta_yml_path: meta)
      runner = Hive::PlanReview::PlannerRevision::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      spawn = lambda do |_task, **kwargs|
        File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
        { status: :ok, usage: { model: "served-model" } }
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        observed = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
      end

      assert_equal "terminal_failure", observed.fetch("status")
      assert_includes observed.fetch("diagnostic"), "custody was not invoked"
    end
  end

  def test_production_runner_preserves_preflight_failure_before_agent_custody
    Dir.mktmpdir("hive-plan-revision-preflight") do |root|
      meta = File.join(root, "meta.yml")
      File.write(meta, "id: demo\n")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "input-plan.md"), "# Plan\n")
      task = RunnerTask.new(folder: root, meta_yml_path: meta)
      runner = Hive::PlanReview::PlannerRevision::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      preflight_failure = lambda do |_task, **|
        { status: :error, error_message: "provider route preflight failed" }
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, preflight_failure) do
        observed = runner.call(
          prompt: "revise", workspace:,
          output_path: File.join(workspace, "candidate-output.md"),
          planner_identity:, timeout_sec: 60
        )
      end

      assert_equal "retryable_failure", observed.fetch("status")
      assert_equal "provider route preflight failed", observed.fetch("diagnostic")
    end
  end

  def test_revision_normalizes_failed_runner_object_findings_and_candidate_path_errors
    project = Dir.mktmpdir("hive-plan-revision-branches")
    initialize_repository(project)
    task_folder = File.join(project, ".hive-state", "stages", "3-plan", "demo")
    FileUtils.mkdir_p(task_folder)
    task = Task.new(folder: task_folder, project_root: project)
    failed = Hive::PlanReview::PlannerRevision.new(
      task:, cfg: {}, runner: ->(**) { { "status" => "timeout", "diagnostic" => "slow" } }
    ).call(
      review_id: "pr-#{'d' * 64}", plan_bytes: "# Plan\n", findings: [],
      planner_identity:, timeout_sec: 60
    )
    assert_equal "timeout", failed.outcome
    assert_equal "slow", failed.diagnostic

    finding = Struct.new(:title) { def to_h = { "title" => title } }.new("Review me")
    service = Hive::PlanReview::PlannerRevision.new(
      task:, cfg: {}, runner: lambda do |prompt:, output_path:, **|
        assert_includes prompt, "Review me"
        File.write(output_path, "# Revised\n<!-- COMPLETE -->\n")
        { "status" => "success" }
      end
    )
    assert service.call(
      review_id: "pr-#{'e' * 64}", plan_bytes: "# Plan\n", findings: [ finding ],
      planner_identity:, timeout_sec: 60
    ).success?

    workspace = Dir.mktmpdir("hive-plan-revision-paths")
    assert_raises(Hive::PlanReview::InvalidRecord) do
      service.send(:read_candidate!, File.join(File.dirname(workspace), "escape.md"), workspace)
    end
    error = assert_raises(Hive::PlanReview::InvalidRecord) do
      service.send(:read_candidate!, File.join(workspace, "missing.md"), workspace)
    end
    assert_includes error.message, "did not publish"
  ensure
    FileUtils.remove_entry(project) if project && File.exist?(project)
    FileUtils.remove_entry(workspace) if workspace && File.exist?(workspace)
  end

  def test_codex_planner_revision_runs_inside_a_disposable_git_worktree
    Dir.mktmpdir("hive-plan-revision-codex") do |root|
      initialize_repository(root)
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      observed_workspace = nil
      runner = lambda do |workspace:, output_path:, **|
        observed_workspace = workspace
        assert system(
          "git", "-C", workspace, "rev-parse", "--is-inside-work-tree",
          out: File::NULL, err: File::NULL
        ), "Codex planner revision cwd must be a Git checkout"
        refute_equal File.expand_path(root), File.expand_path(workspace)
        File.write(output_path, "# Revised\n<!-- COMPLETE -->\n")
        { "status" => "success" }
      end
      identity = planner_identity.merge("provider" => "codex")
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder, project_root: root), cfg: {}, runner:
      )

      result = service.call(
        review_id: "pr-#{'f' * 64}", plan_bytes: "# Plan\n", findings: [],
        planner_identity: identity, timeout_sec: 60
      )

      assert result.success?
      refute File.exist?(observed_workspace), "disposable planner worktree must be removed"
    end
  end

  private

  def initialize_repository(root)
    File.write(File.join(root, "README.md"), "fixture\n")
    commands = [
      %w[git init -q],
      %w[git config user.email hive@example.test],
      %w[git config user.name Hive],
      %w[git add README.md],
      %w[git commit -qm initial]
    ]
    commands.each do |command|
      assert system(*command, chdir: root, out: File::NULL, err: File::NULL),
             "fixture Git command failed: #{command.join(' ')}"
    end
  end

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end
end
