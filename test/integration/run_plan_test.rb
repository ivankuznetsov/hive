require "test_helper"
require "digest"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/plan_review/orchestrator"

class RunPlanTest < Minitest::Test
  include HiveTestHelper

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
          set_project_claude_mode(dir, "headless")
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
          set_project_claude_mode(dir, "headless")
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

  def test_public_plan_stage_runs_standard_and_mandatory_revision_and_verification
    {
      "standard" => standard_review_plan,
      "mandatory" => mandatory_review_plan
    }.each do |expected_level, plan|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io do
            Hive::Commands::Init.new(dir).call
            set_project_claude_mode(dir, "headless")
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
          assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
          assert_equal 1, revision.calls.length
          assert_equal candidate, File.read(plan_md)
        end
      end
    end
  end

  private

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
