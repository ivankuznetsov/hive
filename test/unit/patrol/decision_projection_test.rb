require "test_helper"
require "hive/patrol/decision_projection"

class PatrolDecisionProjectionTest < Minitest::Test
  def test_schedule_projection_covers_every_trigger_and_disabled_selection
    cases = [
      [ false, "timer", true, nil, "disabled" ],
      [ true, "timer", true, nil, "due" ],
      [ true, "timer", false, nil, "not_due" ],
      [ true, "continuous", false, true, "due" ],
      [ true, "continuous", true, false, "due" ],
      [ true, "continuous", false, false, "not_due" ],
      [ true, "new_commits", nil, true, "due" ],
      [ true, "new_commits", nil, false, "not_due" ]
    ]

    cases.each do |enabled, trigger, timer_due, branch_changed, rationale|
      input = Hive::Patrol::DecisionProjection.schedule_input(
        enabled: enabled,
        trigger: trigger,
        timer_due: timer_due,
        branch_changed: branch_changed
      )

      assert_equal(
        rationale,
        Hive::Patrol::DecisionProjection.project(input).rationale,
        input.inspect
      )
    end
  end

  def test_unknown_selection_kind_is_rejected_before_a_projection_is_built
    error = assert_raises(Hive::ConfigError) do
      Hive::Patrol::DecisionProjection.project(
        "kind" => "manual", "operation" => "operator-request"
      )
    end

    assert_equal "ordinary patrol selection input is malformed", error.message
  end
end
