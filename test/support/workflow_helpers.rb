require "hive/workflow"
require "hive/workflows/registry"

module HiveWorkflowTestHelper
  def research_workflow
    Hive::Workflow.new(
      id: :research,
      stages: [
        Hive::Workflow::Stage.new(name: "intake", index: 1, state_file: "intake.md", kind: :inert),
        Hive::Workflow::Stage.new(name: "gather", index: 2, state_file: "notes.md", kind: :agent),
        Hive::Workflow::Stage.new(name: "report", index: 3, state_file: "report.md", kind: :marker)
      ]
    )
  end

  def with_registered_workflow(descriptor)
    original_fetch = Hive::Workflows::Registry.method(:fetch)
    Hive::Workflows::Registry.define_singleton_method(:fetch) do |id|
      id == descriptor.id ? descriptor : original_fetch.call(id)
    end
    yield
  ensure
    Hive::Workflows::Registry.define_singleton_method(:fetch, original_fetch) if original_fetch
  end
end
