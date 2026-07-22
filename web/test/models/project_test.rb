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
end
