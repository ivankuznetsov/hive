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
  end
end
