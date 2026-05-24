require "test_helper"
require "hive/task_resolver"

class TaskResolverTest < Minitest::Test
  include HiveTestHelper

  def test_path_target_rejects_mismatched_stage_filter
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", "demo-task")
      FileUtils.mkdir_p(folder)
      write_registered_project(home, "project-a", project_root)

      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::TaskResolver.new(folder, stage_filter: "brainstorm").resolve
      end

      assert_includes error.message, "TARGET is at 3-plan"
      assert_includes error.message, "--stage/--from says 2-brainstorm"
    end
  end

  private

  def write_registered_project(home, name, project_root)
    File.write(
      File.join(home, "config.yml"),
      {
        "registered_projects" => [
          {
            "name" => name,
            "path" => project_root,
            "hive_state_path" => File.join(project_root, ".hive-state")
          }
        ]
      }.to_yaml
    )
  end
end
