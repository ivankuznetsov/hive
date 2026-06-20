require "test_helper"
require "hive/workflow_selection"

class WorkflowSelectionTest < Minitest::Test
  def test_fetch_returns_registered_workflow
    with_registered_workflow(content_workflow) do
      assert_equal :content_fixture, Hive::WorkflowSelection.fetch!("content_fixture").id
    end
  end

  def test_fetch_defaults_blank_to_coding
    assert_equal :coding, Hive::WorkflowSelection.fetch!("").id
    assert_equal :coding, Hive::WorkflowSelection.fetch!(nil).id
  end

  def test_fetch_unknown_lists_valid_names
    with_registered_workflow(content_workflow) do
      error = assert_raises(Hive::Workflows::UnknownWorkflow) do
        Hive::WorkflowSelection.fetch!("bogus")
      end

      assert_includes error.message, "unknown workflow \"bogus\""
      assert_includes error.message, "coding"
      assert_includes error.message, "content_fixture"
      assert_equal "bogus", error.value, "the user-supplied name must travel as a structured field"
      assert_includes error.valid, "content_fixture", "the valid-names list must travel as a structured field"
    end
  end

  def test_valid_names_reflect_registry
    with_registered_workflow(content_workflow) do
      assert_includes Hive::WorkflowSelection.valid_names, "content_fixture"
    end
  end
end
