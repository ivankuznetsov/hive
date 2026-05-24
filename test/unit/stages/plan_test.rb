require "test_helper"
require "hive/stages/plan"

class HiveStagesPlanTest < Minitest::Test
  def test_action_for_known_markers
    assert_equal "draft_updated", Hive::Stages::Plan.action_for(:waiting)
    assert_equal "complete", Hive::Stages::Plan.action_for(:complete)
    assert_equal "error", Hive::Stages::Plan.action_for(:error)
  end

  def test_action_for_unknown_marker_stringifies_marker
    assert_equal "review_waiting", Hive::Stages::Plan.action_for(:review_waiting)
  end
end
