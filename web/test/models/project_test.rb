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
end
