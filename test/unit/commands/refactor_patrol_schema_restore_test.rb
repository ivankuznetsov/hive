require "test_helper"
require "hive/cli"
require "hive/commands/refactor_patrol_schema_restore"

class RefactorPatrolSchemaRestoreCommandTest < Minitest::Test
  include HiveTestHelper

  RestoreResult = Data.define(
    :snapshot_id, :restored_jobs, :quarantine_path
  )

  def test_narrow_cli_command_passes_the_registered_identity_and_emits_json
    with_tmp_dir do |root|
      state = File.join(root, ".custom-state")
      entry = {
        "name" => "demo",
        "project_id" => "project-demo",
        "path" => root,
        "real_path" => File.realpath(root),
        "hive_state_path" => state
      }
      seen = nil
      snapshot_id = "snapshot-#{"a" * 64}"
      command = Hive::Commands::RefactorPatrolSchemaRestore.new(
        "demo",
        snapshot_id,
        json: true,
        project_resolver: ->(name) {
          assert_equal "demo", name
          entry
        },
        restorer: lambda do |identity|
          seen = identity
          RestoreResult.new(
            snapshot_id: snapshot_id,
            restored_jobs: 2,
            quarantine_path: File.join(state, "quarantine")
          )
        end
      )

      output, = capture_io { command.call }
      payload = JSON.parse(output)

      assert_equal state, seen.fetch("hive_state_path")
      assert_equal "hive-refactor-patrol-schema-restore",
                   payload.fetch("schema")
      assert_equal snapshot_id, payload.fetch("snapshot_id")
      assert_equal 2, payload.fetch("restored_jobs")
      assert_equal true, payload.fetch("ok")
      assert Hive::CLI.tasks.key?(
        "refactor_patrol_schema_restore"
      )
    end
  end

  def test_command_rejects_canonical_registration_drift_before_restore
    with_tmp_dir do |root|
      command = Hive::Commands::RefactorPatrolSchemaRestore.new(
        "demo",
        "snapshot-#{"a" * 64}",
        project_resolver: ->(*) {
          {
            "name" => "demo",
            "project_id" => "project-demo",
            "path" => root,
            "real_path" => File.join(root, "old"),
            "hive_state_path" => File.join(root, ".hive-state")
          }
        },
        restorer: ->(*) { flunk "drifted registration reached restore" }
      )

      error = assert_raises(Hive::ConfigError) { command.call }
      assert_match(/canonical path/, error.message)
    end
  end
end
