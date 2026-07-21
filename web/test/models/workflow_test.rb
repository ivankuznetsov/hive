require "test_helper"

class WorkflowTest < ActiveSupport::TestCase
  class FakeLifecycle
    def list(project)
      raise "wrong project" unless project.name == "alpha"

      [
        {
          "name" => "docs", "origin" => "managed", "selection" => "selected",
          "integrity" => "verified", "default" => true, "version" => "1.2.0",
          "source_commit" => "a" * 40, "catalog_visibility" => "public"
        }
      ]
    end
  end

  setup do
    Workflow.lifecycle = FakeLifecycle.new
  end

  teardown do
    Workflow.reset_lifecycle!
  end

  test "wraps lifecycle rows in project-scoped domain objects" do
    project = Project.new("name" => "alpha")
    workflow = Workflow.for(project).sole

    assert_same project, workflow.project
    assert_equal "docs", workflow.name
    assert workflow.managed?
    assert workflow.selected?
    assert workflow.verified?
    assert workflow.default?
    assert_equal "1.2.0", workflow.version
    assert_equal "public", workflow.catalog_visibility
  end
end
