require "test_helper"
require "hive/commands/status"

class CommandsStatusTest < Minitest::Test
  include HiveTestHelper

  def test_json_payload_ignores_archived_manual_stage_sibling
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      active = File.join(hive_state, "stages", "4-execute", "active-task")
      archived = File.join(hive_state, "stages", "archived-manual", "manual-task")
      FileUtils.mkdir_p(active)
      FileUtils.mkdir_p(archived)
      File.write(File.join(active, "task.md"), "# Active\n<!-- EXECUTE_WAITING -->\n")
      File.write(File.join(archived, "task.md"), "# Archived manually\n<!-- MANUAL_STEERING -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])

      slugs = payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }
      assert_includes slugs, "active-task"
      refute_includes slugs, "manual-task"
      assert_equal [], payload.fetch("projects").first.fetch("legacy_stage_dirs"),
                   "archived-manual is an intentional status-private sibling, not a legacy stage"
      assert_nil payload.fetch("projects").first.fetch("legacy_migrate_command")
    end
  end
end
