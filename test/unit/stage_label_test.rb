require "test_helper"
require "hive/stage_label"

class StageLabelTest < Minitest::Test
  def test_formats_known_and_project_authored_stages
    assert_equal "Open PR", Hive::StageLabel.format("5-open-pr")
    assert_equal "Open PR", Hive::StageLabel.format("open-pr")
    assert_equal "Draft API", Hive::StageLabel.format("2-draft_api")
    assert_equal "Stage", Hive::StageLabel.format("2-")
  end
end
