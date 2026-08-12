require "test_helper"
require "digest"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/plan_review"
require "hive/plan_review/orchestrator"

class PlanReviewActionIntegrationTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :folder, :project_root, :hive_state_path, :slug, :id, :stage_index, :stage_name,
    keyword_init: true
  )

  class LifecycleAdapter
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
          "status" => "verified", "evidence" => "candidate addresses the approved finding"
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

  class LifecycleRevision
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

  def test_public_command_emits_schema_valid_action_and_idempotent_replay
    with_current_review do |task, store, current|
      arguments = command_arguments(current)
      first = command(task, store, **arguments)
      out, = capture_io { first.call }
      payload = JSON.parse(out)

      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      assert payload.fetch("applied")
      assert_equal "approved", store.current["findings"].first.fetch("lifecycle")

      replay = command(task, store, **arguments)
      replay_out, = capture_io { replay.call }
      replay_payload = JSON.parse(replay_out)
      assert schema.valid?(replay_payload), schema.validate(replay_payload).to_a.inspect
      refute replay_payload.fetch("applied")
      assert replay_payload.fetch("noop")
      assert_equal 1, store.current["decisions"].length
    end
  end

  def test_stale_observation_emits_typed_error_without_mutation
    with_current_review do |task, store, current|
      cmd = command(
        task, store, **command_arguments(current).merge(
          expected_artifact_digest: "0" * 64
        )
      )
      out, _err, status = with_captured_exit { cmd.call }
      payload = JSON.parse(out)

      assert_equal Hive::ExitCodes::TEMPFAIL, status
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      assert_equal "stale_decision", payload.fetch("error_kind")
      assert_empty store.current["decisions"]
    end
  end

  def test_public_command_resumes_revision_verification_and_candidate_promotion
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "public plan review decision").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        folder = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(folder))
        FileUtils.mv(inbox, folder)
        original = lifecycle_plan
        candidate = original.sub("# Plan", "# Plan\n\nApproved: preserve the compatibility contract.")
        File.write(File.join(folder, "plan.md"), original)
        task = Hive::Task.new(folder)
        finding = lifecycle_finding
        adapter = LifecycleAdapter.new(finding)
        revision = LifecycleRevision.new(candidate)
        route_resolver = method(:lifecycle_route)
        options = {
          adapter:, planner_revision: revision, route_resolver:,
          clock: -> { Time.utc(2026, 8, 12, 12) }
        }
        initial = Hive::PlanReview::Orchestrator.new(
          task:, cfg: Hive::Config.load(dir), planner_identity: planner_identity,
          **options
        ).advance!
        assert_equal "awaiting_decision", initial.record.state

        replacement = lambda do |task:, cfg:, planner_identity:, **|
          Hive::PlanReview::Orchestrator.new(
            task:, cfg:, planner_identity:, **options
          ).advance!
        end
        current = initial.record
        arguments = {
          review_id: current.review_id, task_generation: current.task_generation,
          policy_fingerprint: current.policy_fingerprint,
          expected_artifact_digest: initial.observation_digest,
          target_fingerprint: current["findings"].first.fetch("fingerprint"),
          json: true
        }
        output = nil
        with_replaced_singleton_method(
          Hive::PlanReview::Orchestrator, :run!, replacement
        ) do
          output, = capture_io do
            Hive::Commands::PlanReview.new(folder, "approve-finding", **arguments).call
          end
        end

        payload = JSON.parse(output)
        assert schema.valid?(payload), schema.validate(payload).to_a.inspect
        assert_equal "cleared", payload.fetch("state")
        assert payload.fetch("execution_allowed")
        assert_equal 1, revision.calls.length
        assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
        assert_equal candidate, File.read(File.join(folder, "plan.md"))
        assert_equal "verified", Hive::PlanReview::Store.new(
          task_folder: folder
        ).current["findings"].first.fetch("lifecycle")
      end
    end
  end

  private

  def command(task, store, **arguments)
    Hive::Commands::PlanReview.new(
      task.folder, "approve-finding", **arguments, json: true,
      resolver: -> { task },
      service_factory: lambda do |resolved|
        Hive::PlanReview::DecisionService.new(
          task: resolved, clock: -> { Time.utc(2026, 8, 12, 12) },
          task_locker: ->(&block) { block.call },
          commit_locker: ->(&block) { block.call }, committer: ->(*) { }
        )
      end,
      resumer: ->(_resolved) { Hive::PlanReview::Projection.new(store.current) }
    )
  end

  def command_arguments(current)
    {
      review_id: current.review_id, task_generation: current.task_generation,
      policy_fingerprint: current.policy_fingerprint,
      expected_artifact_digest: Hive::PlanReview::Projection.new(current).observation_digest,
      target_fingerprint: current["findings"].first.fetch("fingerprint")
    }
  end

  def with_current_review
    Dir.mktmpdir("hive-plan-review-command") do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        folder:, project_root: root, hive_state_path: File.join(root, ".hive-state"),
        slug: "demo-task", id: "task-1", stage_index: 3, stage_name: "plan"
      )
      store = Hive::PlanReview::Store.new(task_folder: folder)
      manifest = Hive::PlanReview::Record.new(
        "schema" => "hive-plan-review", "schema_version" => 1, "kind" => "manifest",
        "review_id" => "pr-#{'a' * 64}", "prior_review_id" => nil,
        "task_id" => "task-1", "task_generation" => "generation-1",
        "plan_digest" => "b" * 64, "policy_fingerprint" => "c" * 64,
        "computed_level" => "standard", "effective_level" => "standard",
        "created_at" => "2026-08-12T12:00:00Z"
      )
      store.create_review!(manifest)
      finding = Hive::PlanReview::Finding.new(
        "source" => "whole_document", "classification" => "gated_auto",
        "risk" => "medium", "title" => "Confirm compatibility",
        "description" => "The response contract needs approval.",
        "evidence" => {
          "path" => "plan.md", "start_line" => 3, "end_line" => 4,
          "anchor_digest" => "d" * 64
        },
        "lifecycle" => "open", "display_order" => 1
      )
      projection = Hive::PlanReview::Record.new(
        manifest.to_h.merge(
          "kind" => "projection", "version" => 1, "candidate_plan_digest" => nil,
          "state" => "awaiting_decision", "outcome" => nil,
          "attempt_ids" => [], "current_attempt_id" => nil, "coverage" => [],
          "findings" => [ finding.to_h ], "decisions" => [], "routes" => [],
          "artifacts" => {}, "blockers" => [], "required_action" => "approve finding",
          "degradation_reason" => nil, "execution_allowed" => false,
          "updated_at" => "2026-08-12T12:00:00Z"
        )
      )
      store.publish_current!(projection, expected_version: nil)
      yield task, store, store.current
    end
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-plan-review-action")))
    )
  end

  def lifecycle_plan
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

  def lifecycle_finding
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => "gated_auto",
      "risk" => "medium", "title" => "Preserve compatibility",
      "description" => "The plan needs an explicit compatibility disposition.",
      "evidence" => {
        "path" => "plan.md", "start_line" => 1, "end_line" => 1,
        "anchor_digest" => Digest::SHA256.hexdigest("plan")
      },
      "lifecycle" => "open", "display_order" => 1
    )
  end

  def lifecycle_route(role:, **)
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
end
