require "test_helper"
require "json_schemer"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/task"

class TaskCommandTest < Minitest::Test
  include HiveTestHelper

  def test_native_task_json_emits_the_schema_valid_semantic_workspace
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        project = File.basename(project_root)
        capture_io { Hive::Commands::New.new(project, "inspect task").call }
        folder = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(folder)

        out, err = capture_io do
          Hive::CLI.start([ "task", slug, "--project", project, "--json" ])
        end
        document = JSON.parse(out)
        schemer = JSONSchemer.schema(
          JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 2)))
        )

        assert_empty err
        assert_empty schemer.validate(document).to_a
        assert_equal 2, document.fetch("schema_version")
        assert_equal slug, document.dig("task", "slug")
        assert_equal "idea.md", document.dig("result", "primary", "reference")
        refute document.key?("panels")
        refute_includes document.to_s, project_root
      end
    end
  end
end
