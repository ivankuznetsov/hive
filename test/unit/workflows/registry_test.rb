require "test_helper"
require "hive/workflows/registry"

class WorkflowsRegistryTest < Minitest::Test
  def test_default_returns_coding_workflow
    assert_same Hive::Workflows::Registry.fetch(:coding), Hive::Workflows::Registry.default
    assert_equal :coding, Hive::Workflows::Registry.default.id
    assert Hive::Workflows::Registry.default.frozen?
  end

  def test_fetch_unknown_workflow_raises_typed_error
    error = assert_raises(Hive::Workflows::UnknownWorkflow) do
      Hive::Workflows::Registry.fetch(:nope)
    end

    assert_includes error.message, ":nope"
    assert_includes error.message, ":coding"
    assert_equal :nope, error.value, "the offending id must travel as a structured field, not only in the message"
    assert_includes error.valid, "coding", "the registered-workflow list must travel as a structured field"
  end

  def test_all_and_ids_expose_registered_workflows
    assert_equal [ Hive::Workflows::Registry.fetch(:coding), Hive::Workflows::Registry.fetch(:content) ],
                 Hive::Workflows::Registry.all
    assert_equal [ :coding, :content ], Hive::Workflows::Registry.ids
  end

  def test_registered_test_workflow_is_visible_to_enumeration
    descriptor = research_workflow

    with_registered_workflow(descriptor) do
      assert_same descriptor, Hive::Workflows::Registry.fetch(:research)
      assert_includes Hive::Workflows::Registry.all, descriptor
      assert_includes Hive::Workflows::Registry.ids, :research
    end

    refute_includes Hive::Workflows::Registry.ids, :research
  end
end
