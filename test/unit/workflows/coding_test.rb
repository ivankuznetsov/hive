require "test_helper"
require "hive/workflows/coding"

class WorkflowsCodingTest < Minitest::Test
  def test_descriptor_has_coding_id_and_ordered_stages
    descriptor = Hive::Workflows::Coding::DESCRIPTOR

    assert_equal :coding, descriptor.id
    assert_equal %w[inbox brainstorm plan execute open-pr review artifacts finalize done],
                 descriptor.stages.map(&:name)
    assert_equal (1..9).to_a, descriptor.stages.map(&:index)
    assert descriptor.stages.frozen?
  end

  def test_descriptor_carries_transition_verbs
    verbs = Hive::Workflows::Coding::DESCRIPTOR.stages.map { |stage| stage.advance_verb&.name }

    assert_equal [ nil, "brainstorm", "plan", "develop", "open-pr", "review", "artifacts", "finalize", "archive" ], verbs
    assert Hive::Workflows::Coding::DESCRIPTOR.stages.fetch(1).advance_verb.force_source
    refute Hive::Workflows::Coding::DESCRIPTOR.stages.fetch(1).advance_verb.interactive
  end

  def test_descriptor_carries_inert_stage_metadata
    stages_by_name = Hive::Workflows::Coding::DESCRIPTOR.stages.to_h { |stage| [ stage.name, stage ] }

    assert_equal :agent, stages_by_name.fetch("brainstorm").kind
    assert_equal "/ce-brainstorm", stages_by_name.fetch("brainstorm").skill
    assert_equal :state_file_marker, stages_by_name.fetch("plan").status_mode
    assert_equal :exit_code_only, stages_by_name.fetch("execute").status_mode
    assert_equal 500, stages_by_name.fetch("execute").budget_usd
    assert_equal 14400, stages_by_name.fetch("execute").timeout_sec
    assert_equal :marker, stages_by_name.fetch("review").kind
    assert_nil stages_by_name.fetch("review").status_mode
    assert_equal :inert, stages_by_name.fetch("done").kind
  end
end
