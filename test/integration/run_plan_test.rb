require "test_helper"
require "digest"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/stage_action"
require "hive/daemon/policy"
require "hive/plan_dependency_correction"
require "hive/plan_review/orchestrator"
require "hive/plan_review/transition_guard"
require "hive/stages/plan"
require "hive/task_action"
require_relative "../support/plan_dependency_incident_fixture"

class RunPlanTest < Minitest::Test
  include HiveTestHelper
  include PlanDependencyIncidentFixture

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  class ReviewAdapter
    attr_reader :calls

    def initialize(finding)
      @finding = finding
      @calls = []
    end

    def call(request)
      @calls << request
      findings = request.kind == "primary" ? [ @finding ] : []
      evidence = request.kind == "verification" ? request.verification_findings.map do |entry|
        {
          "finding_fingerprint" => entry.fetch("fingerprint"),
          "status" => "verified", "evidence" => "candidate contains the accepted disposition"
        }
      end : []
      Hive::PlanReview::Adapters::Base::Result.new(
        outcome: "success", findings:, residual_evidence: evidence,
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

  class ReviewRevision
    attr_reader :calls

    def initialize(candidate)
      @candidate = candidate
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "success", candidate_bytes: @candidate,
        candidate_digest: Digest::SHA256.hexdigest(@candidate),
        route_receipt: arguments.fetch(:planner_identity), diagnostic: ""
      )
    end
  end

  class UnavailableAdversarialAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(request)
      @calls << request
      return Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported") if
        request.kind == "adversarial"

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
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def test_plan_stage_writes_plan_md
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "plan stage test").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

        plan_md = File.join(plan_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          files:
            - lib/demo.rb
            - test/demo_test.rb
          ---
          ## Overview
          test

          ## Test scenarios
          - The focused test passes.

          ## Rollback
          Revert the local change; it is reversible.

          ## Implementation Units
          - U1: foo
          <!-- COMPLETE -->
        MD
        capture_io { Hive::Commands::Run.new(plan_dir).call }
        assert_equal :complete, Hive::Markers.current(plan_md).name
        review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
        assert_equal "skipped", review.fetch("state")
        assert_equal true, review.fetch("execution_allowed")
        events = File.readlines(File.join(plan_dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
        event_types = events.map { |event| event.fetch("event_type") }
        assert_includes event_types, "round_complete",
                        "plan stage must emit round_complete on COMPLETE markers (symmetry with brainstorm)"
        assert_operator event_types.index("stage_enter"), :<, event_types.index("round_complete")
        assert_operator event_types.index("round_complete"), :<, event_types.index("stage_exit")
        assert_equal "3-plan", events.first.fetch("stage")
      end
    end
  end

  def test_plan_stage_waiting_emits_round_waiting
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "plan stage waiting").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

        plan_md = File.join(plan_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = low_risk_plan("WAITING")
        capture_io { Hive::Commands::Run.new(plan_dir).call }
        assert_equal :waiting, Hive::Markers.current(plan_md).name
        review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
        assert_equal "skipped", review.fetch("state")
        events = File.readlines(File.join(plan_dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
        event_types = events.map { |event| event.fetch("event_type") }
        assert_includes event_types, "round_waiting",
                        "plan stage must emit round_waiting on WAITING markers (symmetry with brainstorm)"
      end
    end
  end

  def test_plan_checkpoint_is_seeded_atomically_and_survives_marker_changes
    with_tmp_dir do |dir|
      task = make_plan_task(dir)

      assert Hive::Stages::Plan.ensure_durable_checkpoint!(task)
      checkpoint = File.binread(task.state_file)
      assert_includes checkpoint, "## Requirements Trace"
      assert_includes checkpoint, "## Implementation Units"
      refute_match(/<!-- (?:WAITING|COMPLETE) -->/, checkpoint)

      Hive::Markers.set(task.state_file, :agent_working, pid: 123)
      Hive::Markers.set(task.state_file, :error, reason: "provider_error")
      preserved = Hive::Markers.without_markers(File.binread(task.state_file))
      assert_equal checkpoint.rstrip, preserved.rstrip

      refute Hive::Stages::Plan.ensure_durable_checkpoint!(task)
      assert_equal :error, Hive::Markers.current(task.state_file).name
    end
  end

  def test_plan_checkpoint_never_replaces_existing_plan_or_feedback
    with_tmp_dir do |dir|
      task = make_plan_task(dir)
      existing = "# Existing plan\n\n- user feedback\n<!-- ERROR reason=provider_error -->\n"
      File.binwrite(task.state_file, existing)

      refute Hive::Stages::Plan.ensure_durable_checkpoint!(task)
      assert_equal existing, File.binread(task.state_file)
    end
  end

  def test_public_plan_stage_runs_standard_and_mandatory_revision_and_verification
    {
      "standard" => standard_review_plan,
      "mandatory" => mandatory_review_plan
    }.each do |expected_level, plan|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io do
            Hive::Commands::Init.new(dir).call
            Hive::Commands::New.new(File.basename(dir), "#{expected_level} review hook").call
          end
          inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
          slug = File.basename(inbox)
          plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
          FileUtils.mkdir_p(File.dirname(plan_dir))
          FileUtils.mv(inbox, plan_dir)
          File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

          plan_md = File.join(plan_dir, "plan.md")
          ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
          ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = plan
          finding = review_finding
          adapter = ReviewAdapter.new(finding)
          candidate = plan.sub("# Plan", "# Plan\n\nAccepted: add the bounded compatibility guard.")
          revision = ReviewRevision.new(candidate)
          route_resolver = method(:review_route)
          replacement = lambda do |task:, cfg:, planner_identity:, **|
            Hive::PlanReview::Orchestrator.new(
              task:, cfg:, planner_identity:, adapter:, planner_revision: revision,
              route_resolver:,
              clock: -> { Time.utc(2026, 8, 12, 12) }
            ).advance!
          end

          with_replaced_singleton_method(
            Hive::PlanReview::Orchestrator, :run!, replacement
          ) do
            capture_io { Hive::Commands::Run.new(plan_dir).call }
          end

          review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
          assert_equal expected_level, review.fetch("effective_level")
          assert_equal "cleared", review.fetch("state")
          assert review.fetch("execution_allowed")
          # The adversarial leg runs only at plan_review.adversarial_min_level
          # (default mandatory).
          expected_legs = expected_level == "mandatory" ? %w[primary adversarial verification] : %w[primary verification]
          assert_equal expected_legs, adapter.calls.map(&:kind)
          assert_equal 1, revision.calls.length
          assert_equal candidate, File.read(plan_md)
        end
      end
    end
  end

  def test_required_review_keeps_an_agent_complete_plan_at_waiting_until_clearance
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "required review marker").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

        plan_md = File.join(plan_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = mandatory_review_plan
        adapter = UnavailableAdversarialAdapter.new
        route_resolver = method(:review_route)
        replacement = lambda do |task:, cfg:, planner_identity:, **|
          Hive::PlanReview::Orchestrator.new(
            task:, cfg:, planner_identity:, adapter:,
            route_resolver:,
            clock: -> { Time.utc(2026, 8, 12, 12) }
          ).advance!
        end

        with_replaced_singleton_method(
          Hive::PlanReview::Orchestrator, :run!, replacement
        ) do
          capture_io { Hive::Commands::Run.new(plan_dir).call }
        end

        assert_equal :waiting, Hive::Markers.current(plan_md).name
        review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
        assert_equal "mandatory", review.fetch("effective_level")
        assert_equal "reviewing", review.fetch("state")
        refute review.fetch("execution_allowed")
        assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
        events = File.readlines(File.join(plan_dir, "events.jsonl"), chomp: true)
          .map { |line| JSON.parse(line) }
        assert_includes events.map { |event| event.fetch("event_type") }, "round_waiting"
      end
    end
  end

  def test_initial_invalid_plan_list_receives_one_correction_adopts_list_and_clears_review
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(project, "c5 root", slug_override: "c5-root").call
        end
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2,
                                      idempotency_key: "#{project}:F2:v1")
        create_done_prerequisite(dir, slug: "f3-ledger-261030-bbbb", id: 3,
                                      idempotency_key: "#{project}:F3:v1")
        plan_dir = move_stage_task(dir, "c5-root", from: "1-inbox", to: "3-plan")
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")
        plan_md = File.join(plan_dir, "plan.md")

        spawns = []
        first_output = incident_plan_markdown(depends_on: %w[F2 F3], low_risk: true)
        second_output = incident_plan_markdown(
          depends_on: %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb], low_risk: true
        )
        fake_agent = lambda do |_task, _cfg, prompt, _profile, **|
          spawns << prompt
          if spawns.length == 1
            File.write(plan_md, first_output)
          else
            File.write(plan_md, second_output)
          end
          { exit_code: 0, model: "claude-opus-4-6" }
        end

        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, fake_agent) do
          capture_io { Hive::Commands::Run.new(plan_dir).call }
        end

        assert_equal 2, spawns.length, "initial invalid plan must receive exactly one correction"
        assert_includes spawns[1], "F2"
        assert_includes spawns[1], "F3"
        assert_includes spawns[1], "f2-payments-261030-aaaa"
        assert_includes spawns[1], "f3-ledger-261030-bbbb"
        assert_equal :complete, Hive::Markers.current(plan_md).name
        assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb],
                     Hive::TaskMeta.read(plan_dir)[:depends_on]
        review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
        assert_equal "skipped", review.fetch("state")
        assert_equal true, review.fetch("execution_allowed")
        task = Hive::Task.new(plan_dir)
        projection = Hive::PlanReview::Projection.load(task_folder: plan_dir)
        freshness = Hive::PlanReview::TransitionGuard.freshness(
          task: task, projection: projection, config: Hive::Config.load(dir)
        )
        assert_equal "current", freshness.fetch("status")
        state = Hive::PlanDependencyCorrection.read(plan_dir)
        assert_equal false, state.dig("initial", "exhausted")
      end
    end
  end

  def test_permanent_initial_defect_holds_for_operator_and_explicit_hive_plan_recovers_once
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        project = File.basename(dir)
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(project, "c5 root", slug_override: "c5-root").call
        end
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2,
                                      idempotency_key: "#{project}:F2:v1")
        create_done_prerequisite(dir, slug: "f3-ledger-261030-bbbb", id: 3,
                                      idempotency_key: "#{project}:F3:v1")
        plan_dir = move_stage_task(dir, "c5-root", from: "1-inbox", to: "3-plan")
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")
        plan_md = File.join(plan_dir, "plan.md")

        spawns = []
        outputs = [
          incident_plan_markdown(depends_on: %w[F2 F3], low_risk: true),
          incident_plan_markdown(depends_on: %w[F2 ghost-unknown-slug], low_risk: true),
          incident_plan_markdown(depends_on: %w[F2 F3], low_risk: true),
          incident_plan_markdown(
            depends_on: %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb], low_risk: true
          )
        ]
        fake_agent = lambda do |_task, _cfg, prompt, _profile, **|
          spawns << prompt
          File.write(plan_md, outputs.shift)
          { exit_code: 0, model: "claude-opus-4-6" }
        end

        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, fake_agent) do
          capture_io do
            err = assert_raises(Hive::TaskInErrorState) do
              Hive::Commands::Run.new(plan_dir).call
            end
            assert_includes err.message, "plan_dependency_correction_exhausted"
          end
        end

        assert_equal 2, spawns.length
        assert_equal :error, Hive::Markers.current(plan_md).name
        assert_nil Hive::TaskMeta.read(plan_dir)[:depends_on]
        refute File.exist?(File.join(plan_dir, "plan-review", "current.json"))
        state = Hive::PlanDependencyCorrection.read(plan_dir)
        assert_equal true, state.dig("initial", "exhausted")
        first_invocation_id = state.dig("initial", "invocation_id")

        task = Hive::Task.new(plan_dir)
        action = Hive::TaskAction.for(task, Hive::Markers.current(plan_md), config: Hive::Config.load(dir))
        assert_equal Hive::Schemas::TaskActionKind::ERROR, action.key
        assert_nil action.command
        assert_equal :skip, Hive::Daemon::Policy.decide(
          action: action.key, stage: "3-plan", command: action.command,
          state_file_mtime: File.mtime(plan_md), last_dispatched_state_file_mtime: nil,
          blocked: true, admission_error: true, dependency_correction_exhausted: true,
          now: Time.now.utc
        )

        # Generic run and automated daemon dispatch refuse without spending another spawn.
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, fake_agent) do
          err = assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::Run.new(plan_dir, quiet: true).call
          end
          assert_equal "plan_dependency_invalid", err.reason_code

          with_env("HIVE_DAEMON_AUTOMATED_DISPATCH" => "1") do
            auto_err = assert_raises(Hive::DependencyAdmissionError) do
              Hive::Commands::StageAction.new("plan", "c5-root", project: project, from: "3-plan").call
            end
            assert_equal "plan_dependency_invalid", auto_err.reason_code
          end
        end
        assert_equal 2, spawns.length

        # Explicit operator root repair starts one fresh bounded invocation even with invalid bytes in plan.md.
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, fake_agent) do
          capture_io do
            Hive::Commands::StageAction.new("plan", "c5-root", project: project, from: "3-plan").call
          end
        end

        assert_equal 4, spawns.length, "explicit root repair grants one fresh invocation with at most one correction"
        assert_includes spawns[2], "ghost-unknown-slug"
        assert_includes spawns[3], "f3-ledger-261030-bbbb"
        assert_equal :complete, Hive::Markers.current(plan_md).name
        assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb],
                     Hive::TaskMeta.read(plan_dir)[:depends_on]
        review = JSON.parse(File.read(File.join(plan_dir, "plan-review", "current.json")))
        assert_equal "skipped", review.fetch("state")
        assert_equal true, review.fetch("execution_allowed")
        repaired_state = Hive::PlanDependencyCorrection.read(plan_dir)
        refute_equal first_invocation_id, repaired_state.dig("initial", "invocation_id")
        assert_equal false, repaired_state.dig("initial", "exhausted")
      end
    end
  end

  private

  def make_plan_task(dir)
    folder = File.join(
      dir, ".hive-state", "stages", "3-plan", "checkpoint-260821-abcd"
    )
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def low_risk_plan(marker)
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      ## Overview
      stub
      ## Test scenarios
      - The focused test passes.
      ## Rollback
      Revert the local change; it is reversible.
      <!-- #{marker} -->
    MD
  end

  def standard_review_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - Run the focused test.
      <!-- COMPLETE -->
    MD
  end

  def mandatory_review_plan
    <<~MD
      ---
      files:
        - config/authentication.rb
        - test/authentication_test.rb
      ---
      # Plan
      ## Test scenarios
      - Verify authentication permissions.
      ## Rollback
      Revert the authentication change before deployment.
      <!-- COMPLETE -->
    MD
  end

  def review_finding
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => "safe_auto",
      "risk" => "low", "title" => "Add a bounded compatibility guard",
      "description" => "The plan should name the bounded compatibility guard.",
      "evidence" => {
        "path" => "plan.md", "start_line" => 1, "end_line" => 1,
        "anchor_digest" => Digest::SHA256.hexdigest("plan")
      },
      "lifecycle" => "open", "display_order" => 1
    )
  end

  def review_route(role:, **)
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
end
