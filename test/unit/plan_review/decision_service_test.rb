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
      reset = store.current["routes"].last
      assert reset.fetch("recovery_reset")
      assert_nil reset["retry_at"]
      refute reset.key?("attempt_id")
    end

    with_service(routes: [ route("unsupported") ]) do |service, _store, record|
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(record, action: "retry", authorized: false))
      end
    end
  end

  def test_retry_can_target_transient_verification_and_request_review_resets_terminal_route
    verification = route("timeout").merge("role" => "verification")
    with_service(routes: [ verification ]) do |service, store, record|
      result = service.apply(**decision_arguments(record, action: "retry", authorized: false))
      assert result.applied
      assert_equal "reviewing", store.current.state
      assert_equal "verification", store.current["routes"].last.fetch("role")
      assert store.current["routes"].last.fetch("recovery_reset")
    end

    with_service(routes: [ route("unsupported") ]) do |service, store, record|
      result = service.apply(**decision_arguments(
        record, action: "request_review", authorized: false
      ))
      assert result.applied
      reset = store.current["routes"].last
      assert reset.fetch("recovery_reset")
      assert_equal "retryable_failure", reset.fetch("outcome")
      refute reset.key?("attempt_id")
    end
  end

  def test_request_review_cannot_clear_a_verification_finding
    blocker = {
      "owner" => "operator", "reason" => "verification_finding",
      "finding_fingerprint" => "prf-#{'f' * 64}"
    }
    with_service(routes: [ route("success").merge("role" => "verification") ],
                 blockers: [ blocker ]) do |service, store, record|
      error = assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(
          record, action: "request_review", authorized: false
        ))
      end

      assert_includes error.message, "linked plan generation"
      assert_equal 1, store.current["routes"].length
    end
  end

  def test_request_review_resets_each_current_terminal_reviewer_route
    primary = route("terminal_failure")
    adversarial = route("unsupported").merge(
      "role" => "adversarial", "attempt_id" => "pra-#{'f' * 64}"
    )
    with_service(routes: [ primary, adversarial ]) do |service, store, record|
      result = service.apply(**decision_arguments(
        record, action: "request_review", authorized: false
      ))

      assert result.applied
      assert_match(/\Areview-[0-9a-f]{64}\z/, result.decision.target_fingerprint)
      resets = store.current["routes"].last(2)
      assert_equal %w[primary adversarial], resets.map { |entry| entry.fetch("role") }
      assert resets.all? { |entry| entry.fetch("recovery_reset") }
      assert resets.all? { |entry| entry.fetch("outcome") == "retryable_failure" }
      assert resets.none? { |entry| entry.key?("attempt_id") }
    end
  end

  def test_request_review_identity_changes_for_a_new_terminal_attempt
    with_service(routes: [ route("terminal_failure") ]) do |service, store, record|
      first = service.apply(**decision_arguments(
        record, action: "request_review", authorized: false
      ))
      current = store.current
      next_route = route("terminal_failure").merge("attempt_id" => "pra-#{'f' * 64}")
      retried = Hive::PlanReview::Record.new(current.to_h.merge(
        "version" => current.version + 1,
        "routes" => current["routes"] + [ next_route ],
        "attempt_ids" => current["attempt_ids"] + [ next_route.fetch("attempt_id") ],
        "current_attempt_id" => next_route.fetch("attempt_id")
      ))
      store.publish_current!(retried, expected_version: current.version)

      second = service.apply(**decision_arguments(
        store.current, action: "request_review", authorized: false
      ))

      assert second.applied
      refute_equal first.decision.target_fingerprint, second.decision.target_fingerprint
      refute_equal first.decision.decision_id, second.decision.decision_id
    end
  end

  def test_action_value_normalization_is_shared_by_cli_and_web_callers
    assert_equal({ "answer" => "yes" }, Hive::PlanReview::DecisionService.action_value(
      "answer-finding", answer: "yes"
    ))
    assert_equal({ "coverage" => "adversarial" }, Hive::PlanReview::DecisionService.action_value(
      "waive_coverage", coverage: "adversarial"
    ))
    assert_equal({}, Hive::PlanReview::DecisionService.action_value("retry"))
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

  def test_invalid_decision_branches_remain_typed_and_fail_closed
    with_service(finding: finding("safe_auto")) do |service, _store, record|
      assert_raises(Hive::PlanReview::ConflictingDecision) do
        service.apply(**decision_arguments(
          record, action: "approve_finding", target: record["findings"].first.fetch("fingerprint")
        ))
      end
    end
    with_service(finding: finding("gated_auto")) do |service, _store, record|
      target = record["findings"].first.fetch("fingerprint")
      assert_raises(Hive::PlanReview::ConflictingDecision) do
        service.apply(**decision_arguments(
          record, action: "answer_finding", target:, value: { "answer" => "no" }
        ))
      end
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(record, action: "answer_finding"))
      end
    end
    with_service do |service, _store, record|
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(
          record, action: "waive_coverage", target: "coverage", value: {}
        ))
      end
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(record, action: "unknown", target: "unknown-target"))
      end
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(record, action: "approve_finding"))
      end
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(
          record, action: "downgrade_level", value: { "level" => "skip" },
          reason: "not mandatory"
        ))
      end
      service.instance_variable_set(
        :@freshness_checker, ->(_current) { raise Hive::PlanReview::StaleObservation, "stale" }
      )
      assert_raises(Hive::PlanReview::StaleDecision) do
        service.apply(**decision_arguments(record, action: "request_review"))
      end
    end
    with_service(level: "mandatory") do |service, _store, record|
      assert_raises(Hive::PlanReview::InvalidAction) do
        service.apply(**decision_arguments(
          record, action: "raise_level", value: { "level" => "mandatory" }
        ))
      end
    end
    with_service(routes: [ route("timeout") ]) do |service, _store, record|
      assert_raises(Hive::PlanReview::StaleDecision) do
        service.apply(**decision_arguments(
          record, action: "retry", target: "pra-#{'0' * 64}", authorized: false
        ))
      end
    end
  end

  def test_persisted_raise_rejects_skip_and_recovers_from_corrupt_prior_receipt
    with_task do |task|
      assert_raises(Hive::PlanReview::InvalidAction) do
        Hive::PlanReview::DecisionService.persist_raise!(
          task:, level: "skip", operator: "alice"
        )
      end
      root = Hive::PlanReview::Store.new(task_folder: task.folder).root
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "level.json"), "not json")
      result = Hive::PlanReview::DecisionService.persist_raise!(
        task:, level: "standard", operator: "alice"
      )
      assert result.fetch("applied")
    end
  end

  private

  def with_service(level: "standard", finding: nil, routes: [], blockers: [], real_task_lock: false)
    with_task do |task|
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      manifest = manifest_record(level:)
      store.create_review!(manifest)
      record = projection_record(manifest, finding:, routes:, blockers:)
      store.publish_current!(record, expected_version: nil)
      options = {
        task:, clock: -> { Time.utc(2026, 8, 12, 12) },
        commit_locker: ->(&block) { block.call }, committer: ->(*) { },
        freshness_checker: ->(_current) { }
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

  def projection_record(manifest, finding:, routes:, blockers:)
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
        "blockers" => blockers, "required_action" => "operator action",
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
