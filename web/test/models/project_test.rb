require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "finds registered projects by their domain name" do
    alpha = Project.new("name" => "alpha", "path" => "/repos/alpha", "hive_state_path" => "/state/alpha")
    beta = Project.new("name" => "beta", "path" => "/repos/beta", "hive_state_path" => "/state/beta")

    assert_same beta, Project.find!("beta", projects: [ alpha, beta ])
    assert_equal "/repos/beta", beta.path
    assert_equal "/state/beta", beta.hive_state_path
  end

  test "raises the typed not-found error for an unknown project" do
    error = assert_raises(Hive::InvalidTaskPath) do
      Project.find!("missing", projects: [])
    end

    assert_equal "unknown project missing", error.message
  end

  test "retains hash access at gem adapter boundaries" do
    project = Project.new("name" => "alpha", "path" => "/repos/alpha")

    assert_equal "alpha", project["name"]
    assert_equal "/repos/alpha", project.fetch("path")
  end

  test "wraps active status rows as tasks" do
    project = Project.new(
      "name" => "alpha",
      "tasks" => [ { "slug" => "ship-it-260720-abcd", "stage" => "3-plan" } ]
    )

    task = project.active_tasks.sole

    assert_instance_of Task, task
    assert_same project, task.project
    assert_equal "ship-it-260720-abcd", task.slug
  end

  test "exposes project hidden count without adding fields to task rows" do
    attributes = {
      "name" => "alpha",
      "hidden_archived_task_count" => 2,
      "tasks" => [ { "slug" => "visible-archive-260720-abcd" } ]
    }
    project = Project.new(attributes)

    assert_equal 2, project.hidden_archived_task_count
    assert_same project.tasks, project.active_tasks
    assert_same project.tasks, project.archived_tasks
    refute project.tasks.sole.instance_variable_get(:@attributes).key?("hidden_archived_task_count")
    assert_equal 0, Project.new("name" => "legacy").hidden_archived_task_count
  end

  test "creates an idea through the project resource" do
    name = create_hive_project!("project-idea-resource")
    project = Project.find!(name)
    inbox = stage_dir(name, "1-inbox")
    before = inbox.children

    capture_io { project.add_idea!("Model the operator's idea") }

    created = inbox.children - before
    assert_equal 1, created.size
    assert_includes created.sole.join("idea.md").read, "Model the operator's idea"
  end

  test "normalizes only idea-capture IO failures and preserves their cause" do
    project = Project.new("name" => "alpha")
    io_error = IOError.new("absolute/path/must/not/reach/the/browser")
    command = Object.new
    command.define_singleton_method(:call!) { raise io_error }

    error = with_replaced_singleton_method(Hive::Commands::New, :new, ->(*) { command }) do
      assert_raises(Project::IdeaCaptureError) { project.add_idea!("Retry me") }
    end

    assert_same io_error, error.cause
    assert_equal IOError, error.cause.class
    refute_includes error.message, io_error.message
  end

  test "does not misclassify programmer errors as idea-capture IO failures" do
    project = Project.new("name" => "alpha")
    command = Object.new
    command.define_singleton_method(:call!) { raise NoMethodError, "broken adapter" }

    with_replaced_singleton_method(Hive::Commands::New, :new, ->(*) { command }) do
      assert_raises(NoMethodError) { project.add_idea!("Expose the defect") }
    end
  end
end
