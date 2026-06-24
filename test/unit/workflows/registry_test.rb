require "test_helper"
require "hive/workflows/registry"
# Pulls in Hive::Workflows.reset_union_cache!, which the shared
# HiveWorkflowTestHelper (with_registered_workflow / reset_workflow_union_cache!)
# delegates to. registry.rb alone does not define it, so an isolated run of this
# file would NoMethodError without this require (full `rake test` only passed by
# load-order luck).
require "hive/workflows"

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
    assert_equal Hive::ExitCodes::USAGE, error.exit_code
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

  def test_register_rejects_builtin_id_collision
    descriptor = Hive::Workflow.new(
      id: :coding,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert)
      ]
    )

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Registry.register!(descriptor, source_path: "/tmp/coding.yml")
    end

    assert_includes error.message, "/tmp/coding.yml"
    assert_includes error.message, "collides with registered workflow :coding"
  end

  def test_register_rejects_runtime_id_collision_without_source_path
    descriptor = research_workflow
    Hive::Workflows::Registry.register!(descriptor)

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Registry.register!(descriptor)
    end

    assert_includes error.message, "workflow :research"
    assert_includes error.message, "collides with registered workflow :research"
  ensure
    Hive::Workflows::Registry.reset_runtime_registrations!
  end
end
