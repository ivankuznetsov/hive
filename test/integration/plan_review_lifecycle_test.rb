require "test_helper"
require "json"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/plan_review"
require "hive/commands/run"
require "hive/commands/stage_action"
require "hive/daemon/plan_approval"
require "hive/daemon/policy"
require "hive/plan_dependency_correction"
require "hive/plan_review/orchestrator"
require "hive/plan_review/transition_guard"
require "hive/task_action"
require_relative "../support/plan_dependency_incident_fixture"

class PlanReviewLifecycleIntegrationTest < Minitest::Test
  include HiveTestHelper
  include PlanDependencyIncidentFixture

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

  # hivedev f4 (2026-11-10): the operator edited plan.md in 6-review, moved the
  # task back to 4-execute, and every daemon `hive develop` refused execute
  # entry as a markerless exit that was healed into an endless generic retry.
  def test_plan_edited_after_review_is_refused_at_reentry_with_a_typed_operator_owned_stop
    with_plan_task(skip_plan) do |dir, task|
      assert_equal "skipped", orchestrator(task, FakeAdapter.new("success")).advance!.record.state
      stages = File.join(dir, ".hive-state", "stages")
      review = File.join(stages, "6-review", task.slug)
      FileUtils.mkdir_p(File.dirname(review))
      FileUtils.mv(task.folder, review)
      File.write(File.join(review, "plan.md"), skip_plan.sub("# Plan\n", "# Plan\nOperator decision: keep v1.\n"))

      # The backward approve now refuses up front and names the remedy.
      _out, approve_error, approve_status = with_captured_exit do
        Hive::Commands::Approve.new(task.slug, to: "4-execute", from: "6-review").call
      end
      assert_equal Hive::ExitCodes::WRONG_STAGE, approve_status
      assert_includes approve_error, "canonical plan changed after plan review"
      assert_includes approve_error, "hive approve #{task.slug} --to 3-plan --from 6-review"
      assert File.directory?(review), "a refused re-entry must leave the task in review"

      # A raw move (or a move made before this preflight existed) still reaches
      # execute entry, which now records the refusal instead of exiting markerless.
      execute = File.join(stages, "4-execute", task.slug)
      FileUtils.mkdir_p(File.dirname(execute))
      FileUtils.mv(review, execute)
      _out, develop_error, develop_status = with_captured_exit do
        Hive::Commands::StageAction.new("develop", task.slug, from: "4-execute").call
      end
      assert_equal Hive::ExitCodes::WRONG_STAGE, develop_status
      assert_includes develop_error, "hive approve #{task.slug} --to 3-plan --from 4-execute"
      refute File.exist?(File.join(execute, "worktree.yml")), "the refusal precedes worktree setup"

      executing = Hive::Task.new(execute)
      marker = Hive::Markers.current(executing.state_file)
      assert_equal [ :error, "plan_review_blocked" ], [ marker.name, marker.attrs["reason"] ]
      assert_equal "complete or resolve the plan review", marker.attrs["required_action"]
      assert_equal "canonical plan changed after plan review", marker.attrs["blocker"]
      action = Hive::TaskAction.for(
        executing, marker, config: Hive::Config.load(executing.project_root),
        project_name: File.basename(dir)
      )
      assert_equal [ "error", "Plan review blocks execution" ], [ action.key, action.label ]
      assert_includes action.diagnostic.fetch("detail"), "hive plan-review-run #{task.slug}"

      # The named remedy works: back to plan clears the stop, and the stale
      # review restarts into a fresh resolution for the edited plan.
      capture_io { Hive::Commands::Approve.new(task.slug, to: "3-plan", from: "4-execute").call }
      plan = Hive::Task.new(File.join(stages, "3-plan", task.slug))
      assert_equal :none, Hive::Markers.current(File.join(plan.folder, "task.md")).name
      stale = Hive::PlanReview::Store.new(task_folder: plan.folder).current_validated
      restart = Hive::Commands::PlanReview.new(
        plan.folder, "restart", review_id: stale.review_id,
        task_generation: stale.task_generation, policy_fingerprint: stale.policy_fingerprint,
        expected_artifact_digest: Hive::PlanReview::Projection.new(stale).observation_digest,
        project: File.basename(dir), json: true,
        resumer: ->(resolved) { orchestrator(resolved, FakeAdapter.new("success")).advance! }
      )
      output, = capture_io { restart.call }
      assert JSON.parse(output).fetch("applied")
      current = Hive::PlanReview::Store.new(task_folder: plan.folder).current_validated
      refute_equal stale.review_id, current.review_id
      assert_equal "current", Hive::PlanReview::TransitionGuard.freshness(
        task: plan, projection: Hive::PlanReview::Projection.new(current),
        config: Hive::Config.load(plan.project_root)
      ).fetch("status")
    end
  end

  # todero (2026-11-20): with Muse and Codex out of quota the operator moved
  # the plan-review reviewer routes in project config. Tasks whose reviews had
  # cleared and that were already executing were then refused at execute
  # entry and parked on `plan_review_blocked`. Rerouting reviewers must not
  # reopen a finished verdict; raising what a review must establish still does.
  def test_reviewer_reroute_in_project_config_keeps_an_executing_review_cleared
    with_plan_task(standard_plan) do |dir, task|
      assert_equal "cleared", orchestrator(task, FakeAdapter.new("success")).advance!.record.state
      execute = File.join(dir, ".hive-state", "stages", "4-execute", task.slug)
      FileUtils.mkdir_p(File.dirname(execute))
      FileUtils.mv(task.folder, execute)
      executing = Hive::Task.new(execute)
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task: executing)

      config_path = File.join(dir, ".hive-state", "config.yml")
      config = YAML.safe_load(File.read(config_path)) || {}
      grok = {
        "agent" => "grok", "model" => "grok-4.7", "family" => "grok",
        "effort" => "xhigh", "route" => "native_grok_build"
      }
      config["plan_review"] = (config["plan_review"] || {}).merge(
        "routes" => {
          "primary" => grok, "verification" => grok.dup, # no YAML aliases
          "adversarial" => {
            "agent" => "claude", "model" => "claude-opus-5-5", "family" => "anthropic",
            "effort" => "xhigh", "route" => "native_claude"
          }
        }
      )
      File.write(config_path, config.to_yaml)

      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task: executing)
      projection = Hive::PlanReview::Projection.load(task_folder: execute)
      assert_equal "current", Hive::PlanReview::TransitionGuard.freshness(
        task: executing, projection:, config: Hive::Config.load(dir)
      ).fetch("status")

      config["plan_review"]["minimum_level"] = "mandatory"
      File.write(config_path, config.to_yaml)
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(task: executing)
      end
      assert_equal "plan review policy changed after resolution", error.blocked_reason
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
      # Standard-level reviews skip the adversarial leg by default.
      assert_equal %w[primary verification], adapter.calls.map(&:kind)
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

  def test_revised_invalid_candidate_corrects_once_and_promotes_preserving_review_identity
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(project, "c5 revision", slug_override: "c5-rev",
                                  depends_on: "f2-payments-261030-aaaa").call
        end
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2,
                                      idempotency_key: "#{project}:F2:v1")
        create_done_prerequisite(dir, slug: "f3-ledger-261030-bbbb", id: 3,
                                      idempotency_key: "#{project}:F3:v1")
        folder = move_stage_task(dir, "c5-rev", from: "1-inbox", to: "3-plan")
        initial_plan = incident_plan_markdown(
          depends_on: "f2-payments-261030-aaaa", low_risk: false, title: "Initial"
        )
        File.write(File.join(folder, "plan.md"), initial_plan)
        task = Hive::Task.new(folder)

        finding = Hive::PlanReview::Finding.new(
          "source" => "whole_document", "classification" => "safe_auto",
          "risk" => "low", "title" => "Add F3 prerequisite",
          "description" => "Declare F3 in frontmatter.",
          "evidence" => {
            "path" => "plan.md", "start_line" => 1, "end_line" => 1,
            "anchor_digest" => Digest::SHA256.hexdigest("plan")
          },
          "lifecycle" => "open", "display_order" => 1
        )
        adapter = Object.new
        adapter.define_singleton_method(:call) do |request|
          findings = request.kind == "primary" ? [ finding ] : []
          evidence = request.kind == "verification" ? request.verification_findings.map do |entry|
            {
              "finding_fingerprint" => entry.fetch("fingerprint"),
              "status" => "verified", "evidence" => "candidate fixed depends_on"
            }
          end : []
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "success", findings: findings, residual_evidence: evidence,
            coverage: request.required_coverage.map { |name| { "name" => name, "required" => true, "status" => "completed" } },
            route_receipt: {
              "role" => request.kind, "requested" => request.reviewer,
              "actual" => request.reviewer, "capability_result" => "present",
              "independence_verified" => true, "independence_reason" => "different_model_family"
            }
          )
        end

        revision_calls = []
        bad_candidate = incident_plan_markdown(
          depends_on: %w[f2-payments-261030-aaaa F3], low_risk: false, title: "Revised bad"
        )
        good_candidate = incident_plan_markdown(
          depends_on: %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb], low_risk: false, title: "Revised good"
        )
        revision_runner = lambda do |**kwargs|
          revision_calls << kwargs
          bytes = revision_calls.length == 1 ? bad_candidate : good_candidate
          Hive::PlanReview::PlannerRevision::Result.new(
            outcome: "success", candidate_bytes: bytes,
            candidate_digest: Digest::SHA256.hexdigest(bytes),
            route_receipt: kwargs.fetch(:planner_identity), diagnostic: ""
          )
        end

        orch = Hive::PlanReview::Orchestrator.new(
          task: task, cfg: Hive::Config.load(dir),
          planner_identity: planner_identity, adapter: adapter,
          planner_revision: revision_runner,
          route_resolver: method(:resolve_route),
          clock: -> { Time.utc(2026, 10, 30, 12) }
        )
        result = orch.advance!

        assert_equal 2, revision_calls.length, "invalid revision candidate must receive exactly one correction"
        assert_includes revision_calls[1].fetch(:dependency_diagnostic), "F3"
        assert_includes revision_calls[1].fetch(:dependency_diagnostic), "f3-ledger-261030-bbbb"
        assert_equal "cleared", result.record.state
        assert_equal true, result.record.execution_allowed?
        assert_equal good_candidate, File.read(File.join(folder, "plan.md"))
        assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb],
                     Hive::TaskMeta.read(folder)[:depends_on]
        projection = Hive::PlanReview::Projection.load(task_folder: folder)
        freshness = Hive::PlanReview::TransitionGuard.freshness(
          task: Hive::Task.new(folder), projection: projection, config: Hive::Config.load(dir)
        )
        assert_equal "current", freshness.fetch("status")
      end
    end
  end

  def test_revised_permanent_invalid_candidate_blocks_without_mutating_plan_or_metadata
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(project, "c5 rev fail", slug_override: "c5-rev-fail",
                                  depends_on: "f2-payments-261030-aaaa").call
        end
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2)
        folder = move_stage_task(dir, "c5-rev-fail", from: "1-inbox", to: "3-plan")
        initial_plan = incident_plan_markdown(
          depends_on: "f2-payments-261030-aaaa", low_risk: false, title: "Initial"
        )
        File.write(File.join(folder, "plan.md"), initial_plan)
        meta_before = File.binread(File.join(folder, "meta.yml"))
        task = Hive::Task.new(folder)

        finding = Hive::PlanReview::Finding.new(
          "source" => "whole_document", "classification" => "safe_auto",
          "risk" => "low", "title" => "Update plan",
          "description" => "Update dependencies.",
          "evidence" => {
            "path" => "plan.md", "start_line" => 1, "end_line" => 1,
            "anchor_digest" => Digest::SHA256.hexdigest("plan")
          },
          "lifecycle" => "open", "display_order" => 1
        )
        adapter = Object.new
        adapter.define_singleton_method(:call) do |request|
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "success",
            findings: request.kind == "primary" ? [ finding ] : [],
            residual_evidence: [],
            coverage: request.required_coverage.map { |name| { "name" => name, "required" => true, "status" => "completed" } },
            route_receipt: {
              "role" => request.kind, "requested" => request.reviewer,
              "actual" => request.reviewer, "capability_result" => "present",
              "independence_verified" => true, "independence_reason" => "different_model_family"
            }
          )
        end

        revision_calls = 0
        unknown_candidate = incident_plan_markdown(
          depends_on: %w[f2-payments-261030-aaaa ghost-unknown-target], low_risk: false, title: "Bad candidate"
        )
        revision_runner = lambda do |**kwargs|
          revision_calls += 1
          Hive::PlanReview::PlannerRevision::Result.new(
            outcome: "success", candidate_bytes: unknown_candidate,
            candidate_digest: Digest::SHA256.hexdigest(unknown_candidate),
            route_receipt: kwargs.fetch(:planner_identity), diagnostic: ""
          )
        end

        orch = Hive::PlanReview::Orchestrator.new(
          task: task, cfg: Hive::Config.load(dir),
          planner_identity: planner_identity, adapter: adapter,
          planner_revision: revision_runner,
          route_resolver: method(:resolve_route),
          clock: -> { Time.utc(2026, 10, 30, 12) }
        )
        result = orch.advance!

        assert_equal 2, revision_calls
        assert_equal "blocked", result.record.state
        refute result.record.execution_allowed?
        assert Hive::PlanDependencyCorrection.plan_review_exhausted?(result.record.to_h)
        assert_equal initial_plan, File.read(File.join(folder, "plan.md"))
        assert_equal meta_before, File.binread(File.join(folder, "meta.yml"))
        action = Hive::TaskAction.for(
          Hive::Task.new(folder), Hive::Markers.current(File.join(folder, "plan.md")),
          config: Hive::Config.load(dir)
        )
        assert_equal Hive::Schemas::TaskActionKind::PLAN_REVIEW_BLOCKED, action.key
        assert_nil action.command
      end
    end
  end

  def test_direct_review_cannot_clear_old_invalid_plan_and_post_clearance_drift_is_rejected
    # Part A: Direct Orchestrator runs across skipped, degraded_cleared, and cleared paths
    # must refuse an existing invalid plan and never publish execution_allowed: true.
    {
      skipped: [ incident_plan_markdown(depends_on: %w[F2 F3], low_risk: true), FakeAdapter.new("success") ],
      degraded: [ incident_plan_markdown(depends_on: %w[F2 F3], low_risk: false), FakeAdapter.new("terminal_failure") ],
      cleared: [ incident_plan_markdown(depends_on: %w[F2 F3], low_risk: false), FakeAdapter.new("success") ]
    }.each do |mode, (plan_text, adapter)|
      with_plan_task(plan_text) do |_dir, task|
        result = orchestrator(task, adapter).advance!
        assert_equal "blocked", result.record.state, "#{mode} path must not clear invalid plan"
        refute result.record.execution_allowed?, "#{mode} path must keep execution_allowed=false"
        blockers = Array(result.record.to_h["blockers"])
        assert blockers.any? { |b| b["reason"].to_s.include?("plan_dependency") },
               "#{mode} blocker must record plan dependency failure: #{blockers.inspect}"
      end
    end

    # Part B: Post-clearance metadata drift is rejected even though depends_on is excluded from task_generation.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(project, "drift guard", slug_override: "drift-guard",
                                  depends_on: "f2-payments-261030-aaaa").call
        end
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2)
        create_done_prerequisite(dir, slug: "f3-ledger-261030-bbbb", id: 3)
        folder = move_stage_task(dir, "drift-guard", from: "1-inbox", to: "3-plan")
        File.write(
          File.join(folder, "plan.md"),
          incident_plan_markdown(depends_on: "f2-payments-261030-aaaa", low_risk: true)
        )
        task = Hive::Task.new(folder)
        cleared = orchestrator(task, FakeAdapter.new("success")).advance!
        assert_equal "skipped", cleared.record.state
        assert cleared.record.execution_allowed?
        observation = Hive::PlanReview::TransitionGuard.prepare_existing!(
          task: task, destination: "4-execute", config: Hive::Config.load(dir)
        )

        # Drift metadata depends_on after clearance: task_generation stays identical.
        Hive::TaskMeta.rewrite(folder, { depends_on: "f3-ledger-261030-bbbb" })
        drifted_task = Hive::Task.new(folder)
        projection = Hive::PlanReview::Projection.load(task_folder: folder)
        assert_equal "current",
                     Hive::PlanReview::TransitionGuard.freshness(
                       task: drifted_task, projection: projection, config: Hive::Config.load(dir)
                     ).fetch("status")

        assert_raises(Hive::PlanReview::TransitionBlocked) do
          Hive::PlanReview::TransitionGuard.verify!(
            task: drifted_task, destination: "4-execute", observation: observation,
            config: Hive::Config.load(dir)
          )
        end

        approve_err = assert_raises(Hive::PlanReview::TransitionBlocked) do
          Hive::Commands::Approve.new(folder, to: "4-execute", force: true).call
        end
        assert_includes approve_err.message, "plan_dependency_mismatch"

        exec_folder = move_stage_task(dir, "drift-guard", from: "3-plan", to: "4-execute")
        run_err = assert_raises(Hive::DependencyAdmissionError) do
          Hive::Commands::Run.new(exec_folder, quiet: true).call
        end
        assert_equal "plan_dependency_mismatch", run_err.reason_code
      end
    end
  end

  private

  def with_plan_task(plan)
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
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
