require "test_helper"
require "hive/daily_digest/materiality"
require "hive/daily_digest/gap"
require "hive/daily_digest/source_health"
require "hive/task_journal"

class DailyDigestMaterialityTest < Minitest::Test
  def test_matrix_accounts_for_every_authoritative_activity_kind
    assert_equal Hive::TaskJournal::ACTIVITY_KINDS.sort,
                 Hive::DailyDigest::Materiality::MATRIX.keys.sort
  end

  def test_every_material_policy_has_an_owner_or_declared_legacy_fallback
    material = Hive::DailyDigest::Materiality::MATRIX.reject do |_kind, policy|
      policy == :noise
    end.keys.sort
    coverage = Hive::DailyDigest::Materiality::PRODUCER_COVERAGE
    assert_equal material, coverage.keys.sort

    coverage.each do |kind, (status, path)|
      assert_includes %w[instrumented unsupported_legacy], status
      next if status == "unsupported_legacy"

      source = File.read(File.expand_path("../../../#{path}", __dir__))
      assert_includes source, %Q["#{kind}"], "#{kind} must be emitted by #{path}"
    end
  end

  def test_changed_outcomes_are_material_and_runtime_churn_is_not
    changed = classify("stage_transition", "transition" => "completed", "marker" => "complete")
    assert_equal :fact, changed.disposition
    assert_equal "stage_transition", changed.value.fetch("kind")

    %w[attempt_admitted context_launch_captured context_selection_reported
       session_started usage_observed context_revision retry_requested].each do |kind|
      assert_equal :noise, classify(kind).disposition, kind
    end

    failed = classify("session_finished", "outcome" => "failed", "health" => "failed")
    assert_equal :fact, failed.disposition
    assert_equal "failure", failed.value.fetch("category")

    successful = classify("session_finished", "outcome" => "completed", "health" => "healthy")
    assert_equal :noise, successful.disposition
  end

  def test_question_and_answer_facts_use_a_privacy_allowlist
    question = classify(
      "question_asked",
      "question_id" => "Q1", "question_fingerprint" => "f" * 64,
      "question_text" => "secret prompt", "answer_binding" => "secret binding"
    ).value
    answer = classify(
      "answer_recorded",
      "question_id" => "Q1", "answer_fingerprint" => "a" * 64,
      "answer" => "secret answer"
    ).value

    assert_equal({ "question_id" => "Q1" }, question.fetch("details"))
    assert_equal({ "question_id" => "Q1" }, answer.fetch("details"))
    refute_includes JSON.generate([ question, answer ]), "secret"
  end

  def test_activity_gap_becomes_a_bounded_stable_gap
    result = classify("activity_gap", "scope" => "task:demo", "reason" => "x" * 1_000)

    assert_equal :gap, result.disposition
    assert_match(/\Agap:/, result.value.fetch("gap_id"))
    assert_operator result.value.fetch("reason").bytesize, :<=, 240
  end

  def test_malformed_activity_becomes_a_gap_and_facades_share_identity
    malformed = activity("stage_transition", "transition" => "completed")
    malformed["occurred_at"] = "not-a-time"
    result = Hive::DailyDigest::Materiality.classify(
      malformed, project: { "project_id" => "project-1", "name" => "demo" }
    )
    assert_equal :gap, result.disposition
    assert_equal "malformed_activity", result.value.fetch("reason_code")

    attributes = {
      source: "github", scope: "demo", reason_code: "offline", reason: "offline",
      observed_at: "2026-08-30T10:00:00Z", project_id: "project-1"
    }
    gap = Hive::DailyDigest::Gap.build(**attributes)
    health = Hive::DailyDigest::SourceHealth.unavailable(**attributes)
    assert_equal gap.fetch("gap_id"), health.gap.fetch("gap_id")
    refute health.healthy?
  end

  def test_doubly_invalid_activity_uses_the_collector_observation_time_for_its_gap
    malformed = activity("stage_transition", "transition" => "completed")
    malformed["occurred_at"] = "not-a-time"
    malformed["observed_at"] = "also-not-a-time"

    result = Hive::DailyDigest::Materiality.classify(
      malformed,
      project: { "project_id" => "project-1", "name" => "demo" },
      observed_at: "2026-08-30T11:00:00Z"
    )

    assert_equal :gap, result.disposition
    assert_equal "2026-08-30T11:00:00.000000Z", result.value.fetch("observed_at")
  end

  def test_pull_request_activity_exposes_the_closed_direct_link_shape
    fact = classify(
      "pr_observed", "pr_number" => "42",
      "pr_url" => "https://github.com/acme/demo/pull/42",
      "pr_state" => "open", "head_oid" => "a" * 40, "draft" => false
    ).value

    assert_equal 42, fact.dig("pr", "number")
    assert_equal "https://github.com/acme/demo/pull/42", fact.dig("pr", "url")
    assert_equal "open", fact.dig("pr", "state")
    assert_equal "a" * 40, fact.dig("pr", "head_revision")
  end

  def test_creation_and_scalar_details_are_normalized_through_the_safe_schema
    receipt = {
      creation_id: "creation-1", project_id: "project-1", project_name: "demo",
      task_id: "42", task_slug: "demo-task", stage: "0-inbox", workflow: "full",
      created_at: "2026-08-30T10:00:00Z"
    }
    creation = Hive::DailyDigest::Materiality.creation_fact(receipt)
    assert_equal "creation:creation-1", creation.fetch("fact_id")
    assert_equal({ "workflow" => "full" }, creation.fetch("details"))

    fact = classify(
      "resource_limit_observed",
      "resource_kind" => "tokens", "unit" => 3,
      "extra" => [ { nested: true } ]
    ).value
    assert_equal 3, fact.dig("details", "unit")

    failure = classify(
      "session_finished", "outcome" => "failed", "health" => "failed", "timed_out" => true
    ).value
    assert_equal true, failure.dig("details", "timed_out")

    nested = Hive::DailyDigest::Materiality.send(:stringify, [ { nested: true } ])
    assert_equal [ { "nested" => true } ], nested
  end

  def test_healthy_source_health_has_no_gap
    health = Hive::DailyDigest::SourceHealth.healthy(
      source: "project_state", scope: "demo", freshness_at: "2026-08-30T10:00:00Z"
    )

    assert health.healthy?
    assert_nil health.gap
  end

  private

  def classify(kind, payload = {})
    Hive::DailyDigest::Materiality.classify(activity(kind, payload), project: {
      "project_id" => "project-1", "name" => "demo"
    })
  end

  def activity(kind, payload = {})
    {
        "event_id" => "event-#{kind}",
        "event_type" => "activity_recorded",
        "occurred_at" => "2026-08-30T10:00:00.000000Z",
        "observed_at" => "2026-08-30T10:00:01.000000Z",
        "stage" => "4-execute",
        "task" => { "id" => "42", "slug" => "demo-task" },
        "reason" => "#{kind} changed",
        "provenance" => { "source" => "test" },
        "payload" => payload.merge(
          "activity_kind" => kind,
          "operation_id" => "operation:#{kind}"
        )
      }
  end
end
