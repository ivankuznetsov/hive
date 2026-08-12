require "test_helper"
require "hive/plan_review/decision_service"

class PlanReviewDecisionServiceTest < Minitest::Test
  FakeTask = Struct.new(
    :folder, :project_root, :hive_state_path, :slug, :id, :stage_index, :stage_name,
    keyword_init: true
  )

  def test_gated_approval_applies_once_and_identical_replay_is_a_noop
    with_service(finding: finding("gated_auto")) do |service, store, record|
      arguments = decision_arguments(record, action: "approve_finding",
                                             target: record["findings"].first.fetch("fingerprint"))
      first = service.apply(**arguments)
      replay = service.apply(**arguments)

      assert first.applied
      assert replay.noop?
      assert_equal "approved", store.current["findings"].first.fetch("lifecycle")
      assert_equal 1, store.current["decisions"].length
    end
  end

  def test_manual_answer_is_not_mistaken_for_verified_resolution
    with_service(finding: finding("manual")) do |service, store, record|
      result = service.apply(**decision_arguments(
        record, action: "answer_finding",
        target: record["findings"].first.fetch("fingerprint"),
        value: { "answer" => "Use the reversible export path." }
      ))

      assert result.applied
      assert_equal "answered", store.current["findings"].first.fetch("lifecycle")
      refute store.current.execution_allowed?
    end
  end

  def test_conflicting_and_stale_decisions_are_rejected
    with_service(finding: finding("manual")) do |service, _store, record|
      target = record["findings"].first.fetch("fingerprint")
      service.apply(**decision_arguments(
        record, action: "answer_finding", target:,
        value: { "answer" => "Use option A." }
      ))

      assert_raises(Hive::PlanReview::ConflictingDecision) do
        service.apply(**decision_arguments(
          record, action: "answer_finding", target:,
          value: { "answer" => "Use option B." }
        ))
      end
    end

    with_service(finding: finding("gated_auto")) do |service, _store, record|
      assert_raises(Hive::PlanReview::StaleDecision) do
        service.apply(**decision_arguments(
          record, action: "approve_finding",
          target: record["findings"].first.fetch("fingerprint"),
          expected_artifact_digest: "0" * 64
        ))
      end
    end
  end

  def test_coverage_waiver_and_mandatory_downgrade_require_exact_authority
    with_service(level: "mandatory") do |service, store, record|
      coverage = record["coverage"].first
      waiver = service.apply(**decision_arguments(
        record, action: "waive_coverage", target: coverage.fetch("fingerprint"),
        value: { "coverage" => coverage.fetch("name") }, reason: "Operator accepts outage."
      ))

      assert waiver.applied
      assert_equal "waived", store.current["coverage"].first.fetch("status")
      current = store.current
      downgrade = service.apply(**decision_arguments(
        current, action: "downgrade_level", value: { "level" => "standard" },
        reason: "Exact review is safe to fail open."
      ))
      assert downgrade.applied
      assert_equal "standard", store.current.effective_level
    end
  end

  def test_authority_actions_reject_agent_origin_and_missing_reason
    with_service(finding: finding("gated_auto")) do |service, _store, record|
      assert_raises(Hive::PlanReview::UnauthorizedAction) do
        service.apply(**decision_arguments(
          record, action: "approve_finding",
          target: record["findings"].first.fetch("fingerprint"),
          origin: "daemon", authorized: false
        ))
      end
    end

    with_service(level: "mandatory") do |service, _store, record|
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(
          record, action: "downgrade_level", value: { "level" => "standard" },
          reason: nil
        ))
      end
    end
  end

  def test_retry_only_accepts_transient_outcomes
    with_service(routes: [ route("timeout") ]) do |service, store, record|
      result = service.apply(**decision_arguments(record, action: "retry", authorized: false))

      assert result.applied
      assert_equal "reviewing", store.current.state
      assert_equal "pra-#{'e' * 64}", result.decision.target_fingerprint
    end

    with_service(routes: [ route("unsupported") ]) do |service, _store, record|
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(record, action: "retry", authorized: false))
      end
    end
  end

  def test_persisted_raise_is_idempotent_and_never_lowers
    with_task do |task|
      first = Hive::PlanReview::DecisionService.persist_raise!(
        task:, level: "mandatory", operator: "alice"
      )
      replay = Hive::PlanReview::DecisionService.persist_raise!(
        task:, level: "mandatory", operator: "alice"
      )

      assert first.fetch("applied")
      refute replay.fetch("applied")
      assert_raises(Hive::PlanReview::InvalidAction) do
        Hive::PlanReview::DecisionService.persist_raise!(
          task:, level: "standard", operator: "alice"
        )
      end
    end
  end

  def test_raise_action_writes_level_receipt_under_the_existing_task_lock
    with_service(real_task_lock: true) do |service, store, record|
      result = service.apply(**decision_arguments(
        record, action: "raise_level", value: { "level" => "mandatory" },
        authorized: false, origin: "daemon"
      ))

      assert result.applied
      receipt = JSON.parse(File.read(File.join(store.root, "level.json")))
      assert_equal "mandatory", receipt.fetch("level")
      assert_equal "reviewing", store.current.state
    end
  end

  private

  def with_service(level: "standard", finding: nil, routes: [], real_task_lock: false)
    with_task do |task|
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      manifest = manifest_record(level:)
      store.create_review!(manifest)
      record = projection_record(manifest, finding:, routes:)
      store.publish_current!(record, expected_version: nil)
      options = {
        task:, clock: -> { Time.utc(2026, 8, 12, 12) },
        commit_locker: ->(&block) { block.call }, committer: ->(*) { }
      }
      options[:task_locker] = ->(&block) { block.call } unless real_task_lock
      service = Hive::PlanReview::DecisionService.new(**options)
      yield service, store, store.current
    end
  end

  def with_task
    Dir.mktmpdir("hive-plan-review-decision") do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      yield FakeTask.new(
        folder:, project_root: root, hive_state_path: File.join(root, ".hive-state"),
        slug: "demo-task", id: "task-1", stage_index: 3, stage_name: "plan"
      )
    end
  end

  def manifest_record(level:)
    Hive::PlanReview::Record.new(
      "schema" => "hive-plan-review", "schema_version" => 1, "kind" => "manifest",
      "review_id" => "pr-#{'a' * 64}", "prior_review_id" => nil,
      "task_id" => "task-1", "task_generation" => "generation-1",
      "plan_digest" => "b" * 64, "policy_fingerprint" => "c" * 64,
      "computed_level" => level, "effective_level" => level,
      "created_at" => "2026-08-12T12:00:00Z"
    )
  end

  def projection_record(manifest, finding:, routes:)
    coverage = {
      "name" => "adversarial", "required" => true, "status" => "failed",
      "fingerprint" => Hive::PlanReview::Identity.coverage(
        review_id: manifest.review_id, name: "adversarial",
        policy_fingerprint: manifest.policy_fingerprint
      )
    }
    Hive::PlanReview::Record.new(
      manifest.to_h.merge(
        "kind" => "projection", "version" => 1, "candidate_plan_digest" => nil,
        "state" => "awaiting_decision", "outcome" => nil,
        "attempt_ids" => routes.map { |entry| entry.fetch("attempt_id") },
        "current_attempt_id" => routes.last&.fetch("attempt_id"),
        "coverage" => [ coverage ], "findings" => Array(finding).map(&:to_h),
        "decisions" => [], "routes" => routes, "artifacts" => {},
        "blockers" => [], "required_action" => "operator action",
        "degradation_reason" => nil, "execution_allowed" => false,
        "updated_at" => "2026-08-12T12:00:00Z"
      )
    )
  end

  def finding(classification)
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => classification,
      "risk" => "high", "title" => "Resolve safety boundary",
      "description" => "The plan needs an explicit operator disposition.",
      "evidence" => {
        "path" => "plan.md", "start_line" => 2, "end_line" => 3,
        "anchor_digest" => "d" * 64
      },
      "lifecycle" => "open", "display_order" => 1
    )
  end

  def route(outcome)
    {
      "role" => "primary", "outcome" => outcome,
      "attempt_id" => "pra-#{'e' * 64}",
      "requested" => {}, "actual" => {}, "capability_result" => "present",
      "independence_verified" => false
    }
  end

  def decision_arguments(record, action:, target: nil, value: nil, reason: nil,
                         expected_artifact_digest: nil, origin: "cli", authorized: true)
    {
      action:, review_id: record.review_id,
      task_generation: record.task_generation,
      policy_fingerprint: record.policy_fingerprint,
      expected_artifact_digest: expected_artifact_digest ||
        Hive::PlanReview::Projection.new(record).observation_digest,
      target_fingerprint: target, value:, reason:, origin:, operator: "alice", authorized:
    }
  end
end
