require "test_helper"
require "hive/recovery/presentation"

class RecoveryPresentationTest < Minitest::Test
  def test_descriptor_failed_edit_does_not_infer_missing_answers_from_unparsed_input
    %w[queued cooldown].each do |status|
      row = input_row.merge("workflow" => "content", "stage" => "2-research",
        "answers_complete" => nil, "recovery" => recovery(status))
      view = Hive::Recovery::Presentation.for_row(row)
      assert_equal status, view.kind
      assert_equal "Needs recovery", view.label
      assert_includes view.detail, "agent_launch_failed"
      refute Hive::Recovery::Presentation.missing_input?(row)
    end
    generic = input_row.merge("workflow" => "content", "answers_complete" => nil)
    assert Hive::Recovery::Presentation.missing_input?(generic)
    assert_nil Hive::Recovery::Presentation.for_row(generic)
  end

  def test_complete_input_without_failure_evidence_uses_actual_hold_without_recovery_label
    [ { "blocked" => true, "blocked_by" => "base-task" }, { "held" => "capacity" } ].each do |hold|
      view = Hive::Recovery::Presentation.for_row(input_row.merge(hold))
      assert_equal "hold", view.kind
      assert_equal "Waiting", view.label
      refute_includes view.detail.downcase, "recovery"
      assert_includes view.detail, hold["blocked_by"] || hold["held"]
    end
  end

  def test_dependency_hold_precedes_missing_answers_but_cooldown_does_not
    missing = input_row.merge("answers_complete" => false, "unanswered_questions" => 1,
      "recovery" => recovery("cooldown"))
    assert_equal "input", Hive::Recovery::Presentation.for_row(missing).kind
    blocked = missing.merge("blocked" => true, "blocked_by" => "base-task",
      "recovery" => missing["recovery"].merge("scheduler_hold" => "blocked on base-task; owner scheduler"))
    view = Hive::Recovery::Presentation.for_row(blocked)
    assert_equal "hold", view.kind
    assert_includes view.detail, "blocked on base-task; owner scheduler"
    refute_includes view.detail, "questions need an answer"
    parked = missing.merge("recovery" => recovery("blocked").merge("escalation_tier" => "parked", "owner" => "operator"))
    assert_equal "Needs execution repair", Hive::Recovery::Presentation.for_row(parked).label
  end

  private

  def input_row
    { "action" => "needs_input", "action_label" => "Answer questions", "workflow" => "coding",
      "stage" => "2-brainstorm", "answers_complete" => true, "unanswered_questions" => 0 }
  end

  def recovery(status)
    { "status" => status, "variant" => "failed_edit", "failure_origin" => "agent_launch_failed",
      "owner" => "scheduler", "next_eligible_at" => "2026-11-03T12:00:00Z", "scheduler_status" => "current" }
  end
end
