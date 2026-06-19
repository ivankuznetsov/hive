require "test_helper"
require "hive/workflow"

class WorkflowTest < Minitest::Test
  def test_stage_dir_joins_index_and_name
    stage = Hive::Workflow::Stage.new(name: "execute", index: 4, state_file: "task.md")

    assert_equal "4-execute", stage.dir
  end

  def test_stage_defaults_optional_descriptor_fields
    stage = Hive::Workflow::Stage.new(name: "plan", index: 3, state_file: "plan.md")

    assert_nil stage.advance_verb
    assert_nil stage.kind
    assert_nil stage.skill
    assert_nil stage.status_mode
    assert_nil stage.budget_usd
    assert_nil stage.timeout_sec
    assert_nil stage.capability
  end

  def test_advance_verb_defaults_flags_to_false
    verb = Hive::Workflow::AdvanceVerb.new(name: "plan")

    assert_equal "plan", verb.name
    refute verb.force_source
    refute verb.interactive
  end

  def test_advance_verb_can_flag_interactive
    verb = Hive::Workflow::AdvanceVerb.new(name: "manual-review", interactive: true)

    assert verb.interactive, "interactive: true must surface on the value object the VERBS derivation reads"
  end

  def test_workflow_freezes_stage_array
    stages = [
      Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md")
    ]

    workflow = Hive::Workflow.new(id: :coding, stages: stages)

    assert workflow.frozen?
    assert workflow.stages.frozen?
    refute stages.frozen?, "the caller's array must stay unfrozen — the workflow freezes its own dup"
  end

  def test_value_objects_are_immutable_and_copyable
    stage = Hive::Workflow::Stage.new(
      name: "brainstorm",
      index: 2,
      state_file: "brainstorm.md",
      advance_verb: Hive::Workflow::AdvanceVerb.new(name: "brainstorm", force_source: true)
    )

    assert stage.frozen?
    assert_raises(FrozenError) { stage.instance_variable_set(:@name, "plan") }

    copy = stage.with(index: 3, name: "plan", state_file: "plan.md")

    assert_equal "3-plan", copy.dir
    assert_equal "2-brainstorm", stage.dir
  end
end
