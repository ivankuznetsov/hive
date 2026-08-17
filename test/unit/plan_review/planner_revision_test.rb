require "test_helper"
require "hive/plan_review/planner_revision"

class PlanReviewPlannerRevisionTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, keyword_init: true)
  RunnerTask = Struct.new(:folder, :meta_yml_path, keyword_init: true)

  def test_accepts_one_complete_candidate_and_leaves_input_plan_untouched
    Dir.mktmpdir("hive-plan-revision") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      canonical = File.join(task_folder, "plan.md")
      File.write(canonical, "# Original\n<!-- COMPLETE -->\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- COMPLETE -->\n")
        { "status" => "success", "actual_route" => planner_identity }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder), cfg: {}, runner:
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
      task_folder = File.join(root, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_folder)
      runner = lambda do |output_path:, **|
        File.write(output_path, "# Revised\n<!-- WAITING -->\n")
        { "status" => "success" }
      end
      service = Hive::PlanReview::PlannerRevision.new(
        task: Task.new(folder: task_folder), cfg: {}, runner:
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
        task: Task.new(folder: task_folder), cfg: {}, runner:
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

      tamper = lambda do |_task, **kwargs|
        File.write(meta, "changed: true\n")
        File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
        { status: :ok, usage: { model: "served-model" } }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, tamper) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "terminal_failure", result.fetch("status")
        assert_includes result.fetch("diagnostic"), "protected artifacts"
      end

      missing = ->(_task, **) { { status: :failed, error_message: "no candidate" } }
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, missing) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "retryable_failure", result.fetch("status")
        assert_equal "no candidate", result.fetch("diagnostic")
      end

      success = lambda do |_task, **kwargs|
        File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
        { status: :ok, usage: { model: "served-model" } }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, success) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "success", result.fetch("status")
        assert_equal "served-model", result.dig("actual_route", "model")
      end

      timed_out_complete = lambda do |_task, **kwargs|
        File.write(kwargs.fetch(:expected_output), "# Candidate\n<!-- COMPLETE -->\n")
        { status: :timeout, timed_out: true }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, timed_out_complete) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "success", result.fetch("status")
        assert_includes result.fetch("diagnostic"), "salvaged complete candidate"
      end

      capture_error = ->(_manifest) { raise Hive::ArtifactFirewall::Error, "capture failed" }
      with_replaced_singleton_method(Hive::ArtifactFirewall, :capture, capture_error) do
        result = runner.call(
          prompt: "revise", workspace:, output_path: output,
          planner_identity:, timeout_sec: 60
        )
        assert_equal "terminal_failure", result.fetch("status")
        assert_equal "capture failed", result.fetch("diagnostic")
      end
    end
  end

  def test_revision_normalizes_failed_runner_object_findings_and_candidate_path_errors
    task = Task.new(folder: Dir.mktmpdir("hive-plan-revision-branches"))
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
    FileUtils.remove_entry(task.folder) if task&.folder && File.exist?(task.folder)
    FileUtils.remove_entry(workspace) if workspace && File.exist?(workspace)
  end

  private

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end
end
