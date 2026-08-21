require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/plan_review"
require "hive/commands/stage_action"
require "hive/plan_review/orchestrator"
require "hive/plan_review/transition_guard"

class PlanReviewLifecycleIntegrationTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  class FakeAdapter
    attr_reader :calls

    def initialize(outcome)
      @outcome = outcome
      @calls = []
    end

    def call(request)
      @calls << request
      return Hive::PlanReview::Adapters::Base::Result.new(outcome: @outcome) unless
        @outcome == "success"

      Hive::PlanReview::Adapters::Base::Result.new(
        outcome: "success",
        coverage: request.required_coverage.map do |name|
          { "name" => name, "required" => true, "status" => "completed" }
        end,
        route_receipt: {
          "role" => request.kind, "requested" => request.reviewer,
          "actual" => request.reviewer, "capability_result" => "present",
          "independence_verified" => true,
          "independence_reason" => "different_model_family"
        }
      )
    end
  end

  def setup
    @previous_claude = ENV["HIVE_CLAUDE_BIN"]
    @previous_codex = ENV["HIVE_CODEX_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    ENV["HIVE_CODEX_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @previous_claude
    ENV["HIVE_CODEX_BIN"] = @previous_codex
  end

  def test_mandatory_block_denies_develop_until_exact_downgrade_receipt_clears_it
    with_plan_task(mandatory_plan) do |dir, task|
      unavailable = FakeAdapter.new("unsupported")
      blocked = orchestrator(task, unavailable).advance!

      # A mandatory review that could launch no reviewer resets and retries
      # rather than caching a verdict — but it still refuses to let execution
      # proceed, which is what this test is really about.
      assert_equal "mandatory", blocked.record.effective_level
      assert_equal "reviewing", blocked.record.state
      refute blocked.record.execution_allowed?

      _out, error, status = with_captured_exit do
        Hive::Commands::StageAction.new("develop", task.slug).call
      end
      assert_equal Hive::ExitCodes::WRONG_STAGE, status
      assert_includes error, "restore reviewer capability"
      assert File.directory?(task.folder), "denied transition must leave the task at plan"

      current = Hive::PlanReview::Store.new(task_folder: task.folder).current_validated
      command = Hive::Commands::PlanReview.new(
        task.folder, "downgrade-level", review_id: current.review_id,
        task_generation: current.task_generation,
        policy_fingerprint: current.policy_fingerprint,
        expected_artifact_digest: Hive::PlanReview::Projection.new(current).observation_digest,
        level: "standard", reason: "Operator accepts bounded review unavailability.",
        project: File.basename(dir), json: true,
        resumer: ->(resolved) { orchestrator(resolved, unavailable).advance! }
      )
      output, = capture_io { command.call }
      receipt = JSON.parse(output)

      assert receipt.fetch("applied")
      assert_equal "degraded_cleared", receipt.fetch("state")
      assert receipt.fetch("execution_allowed")
      projected = Hive::PlanReview::Store.new(task_folder: task.folder).current_validated
      assert_equal "standard", projected.effective_level
      assert_equal "degraded_cleared", projected.state
      assert_equal "review_unavailable", projected["degradation_reason"]
      assert_equal "downgrade_level", projected["decisions"].last.fetch("action")
      assert_equal "cli", projected["decisions"].last.fetch("origin")

      _develop_out, _develop_error, develop_status = with_captured_exit do
        Hive::Commands::StageAction.new("develop", task.slug).call
      end
      execute = File.join(dir, ".hive-state", "stages", "4-execute", task.slug)
      assert File.directory?(execute), "fresh degraded clearance must permit exactly one move"
      assert_includes [
        Hive::ExitCodes::SUCCESS, Hive::ExitCodes::SOFTWARE, Hive::ExitCodes::TASK_IN_ERROR
      ], develop_status
      refute File.directory?(task.folder)
    end
  end

  def test_external_plan_edit_creates_a_linked_review_and_keeps_prior_artifacts
    with_plan_task(skip_plan) do |_dir, task|
      first = orchestrator(task, FakeAdapter.new("success")).advance!
      assert_equal "skipped", first.record.state

      File.write(File.join(task.folder, "plan.md"), standard_plan)
      adapter = FakeAdapter.new("success")
      second = orchestrator(task, adapter).advance!

      refute_equal first.record.review_id, second.record.review_id
      assert_equal first.record.review_id, second.record.prior_review_id
      assert_equal "cleared", second.record.state
      assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
      review_root = File.join(task.folder, "plan-review", "reviews")
      assert File.file?(File.join(review_root, first.record.review_id, "manifest.json"))
      assert File.file?(File.join(review_root, second.record.review_id, "manifest.json"))
    end
  end

  def test_execute_task_without_review_root_gets_a_legacy_adoption_receipt
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "legacy execute adoption").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        Hive::TaskMeta.rewrite(inbox, plan_review_required: nil)
        execute = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "plan.md"), standard_plan)
        task = Hive::Task.new(execute)

        assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:)

        receipt = JSON.parse(File.read(
          File.join(execute, "plan-review", "legacy-execute-adoption.json")
        ))
        assert_equal "hive-plan-review-adoption", receipt.fetch("schema")
        assert_equal "pre_feature_execute_task", receipt.fetch("reason")
        assert_equal "4-execute", receipt.fetch("stage")
      end
    end
  end

  def test_raw_move_cannot_adopt_a_new_task_after_required_review_evidence_is_removed
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "required review raw move").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        execute = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "plan.md"), standard_plan)

        error = assert_raises(Hive::PlanReview::TransitionBlocked) do
          Hive::PlanReview::TransitionGuard.validate_execute_entry!(
            task: Hive::Task.new(execute)
          )
        end
        assert_includes error.message, "required plan review evidence is missing"
        refute File.exist?(File.join(execute, "plan-review", "legacy-execute-adoption.json"))
      end
    end
  end

  def test_terminal_outcome_proof_snapshot_is_complete_and_surface_consistent
    fixture = JSON.parse(File.read(
      File.expand_path("../fixtures/plan_review/terminal_outcomes.json", __dir__)
    ))
    outcomes = fixture.fetch("outcomes").to_h { |entry| [ entry.fetch("name"), entry ] }

    assert_equal %w[blocked cleared degraded_cleared skipped], outcomes.keys.sort
    outcomes.each_value do |entry|
      assert_match(/\Apr-[0-9a-f]{64}\z/, entry.fetch("review_id"))
      assert_match(/\A[0-9a-f]{64}\z/, entry.dig("plan", "digest"))
      assert_match(/\A[0-9a-f]{64}\z/, entry.dig("policy", "fingerprint"))
      assert_equal 1, entry.dig("attempts", "current_artifact_sets")
      assert_equal 0, entry.dig("findings", "duplicate_actions")
      assert_equal 1, entry.fetch("surfaces").values.uniq.length
      assert_equal "denied", entry.dig("transition", "before_resolution")
      %w[provider model family effort route].each do |field|
        assert entry.fetch("planner").key?(field), "missing planner #{field}"
      end
    end

    %w[skipped cleared degraded_cleared].each do |name|
      assert outcomes.fetch(name).fetch("execution_allowed")
      assert_equal "allowed_once", outcomes.dig(name, "transition", "after_resolution")
    end
    refute outcomes.fetch("blocked").fetch("execution_allowed")
    assert_equal "still_denied", outcomes.dig("blocked", "transition", "after_resolution")
    assert_equal "review_unavailable", outcomes.dig("degraded_cleared", "degradation_reason")
  end

  private

  def with_plan_task(plan)
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          set_project_claude_mode(dir, "headless")
          Hive::Commands::New.new(File.basename(dir), "plan review lifecycle").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        folder = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(folder))
        FileUtils.mv(inbox, folder)
        File.write(File.join(folder, "plan.md"), plan)
        yield dir, Hive::Task.new(folder)
      end
    end
  end

  def orchestrator(task, adapter)
    Hive::PlanReview::Orchestrator.new(
      task:, cfg: Hive::Config.load(task.project_root),
      planner_identity: planner_identity, adapter:,
      route_resolver: method(:resolve_route),
      clock: -> { Time.utc(2026, 8, 12, 12) }
    )
  end

  def resolve_route(role:, **)
    candidate = {
      "provider" => role == "adversarial" ? "grok" : "codex",
      "model" => role == "adversarial" ? "grok-4.6" : "gpt-5.6-sol",
      "family" => role == "adversarial" ? "grok" : "openai",
      "effort" => "high", "route" => "native_#{role}"
    }
    Hive::PlanReview::RouteResolver::Resolution.new(
      status: "resolved", candidate:,
      receipt: {
        "role" => role, "requested" => candidate, "actual" => candidate,
        "capability_result" => "present", "independence_verified" => true,
        "independence_reason" => "different_model_family"
      }
    )
  end

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end

  def skip_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - Run the focused unit test.
      ## Rollback
      Revert this local and reversible change.
      <!-- COMPLETE -->
    MD
  end

  def standard_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - Run the focused unit test.
      <!-- COMPLETE -->
    MD
  end

  def mandatory_plan
    <<~MD
      ---
      files:
        - config/authentication.rb
        - test/authentication_test.rb
      ---
      # Authentication permissions plan
      ## Test scenarios
      - Verify denied and allowed authentication paths.
      ## Rollback
      Revert the permissions change before deployment.
      <!-- COMPLETE -->
    MD
  end
end
