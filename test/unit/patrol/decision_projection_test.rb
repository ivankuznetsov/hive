require "test_helper"
require "hive/patrol/decision_projection"

class PatrolDecisionProjectionTest < Minitest::Test
  def test_unknown_selection_kind_is_rejected_before_a_projection_is_built
    error = assert_raises(Hive::ConfigError) do
      Hive::Patrol::DecisionProjection.project(
        "kind" => "manual", "operation" => "operator-request"
      )
    end

    assert_equal "ordinary patrol selection input is malformed", error.message
  end
end
