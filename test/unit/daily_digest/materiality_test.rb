require "test_helper"
require "hive/daily_digest/materiality"
require "hive/task_journal"

class DailyDigestMaterialityTest < Minitest::Test
  def test_matrix_accounts_for_every_authoritative_activity_kind
    assert_equal Hive::TaskJournal::ACTIVITY_KINDS.sort,
                 Hive::DailyDigest::Materiality::MATRIX.keys.sort
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

  private

  def classify(kind, payload = {})
    Hive::DailyDigest::Materiality.classify(
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
      },
      project: { "project_id" => "project-1", "name" => "demo" }
    )
  end
end
