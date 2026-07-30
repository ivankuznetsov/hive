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

  def test_default_dependencies_restore_the_registered_project_and_emit_text
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      entry = {
        "name" => "demo",
        "project_id" => "project-demo",
        "path" => root,
        "real_path" => File.realpath(root),
        "hive_state_path" => state
      }
      snapshot_id = "snapshot-#{"b" * 64}"
      result = RestoreResult.new(
        snapshot_id: snapshot_id,
        restored_jobs: 3,
        quarantine_path: File.join(state, "quarantine")
      )
      calls = []

      output, = with_replaced_singleton_method(
        Hive::Config,
        :find_project,
        ->(name) {
          calls << [ :resolve, name ]
          entry
        }
      ) do
        with_replaced_singleton_method(
          Hive::RefactorPatrol::JobStore,
          :restore_schema_v2_snapshot!,
          ->(path, **options) {
            calls << [ :restore, path, options ]
            result
          }
        ) do
          capture_io do
            Hive::Commands::RefactorPatrolSchemaRestore.new(
              "demo", snapshot_id
            ).call
          end
        end
      end

      assert_equal [ :resolve, "demo" ], calls.fetch(0)
      assert_equal :restore, calls.fetch(1).fetch(0)
      assert_equal root, calls.fetch(1).fetch(1)
      assert_equal snapshot_id,
                   calls.fetch(1).fetch(2).fetch(:snapshot_id)
      assert_includes output, "demo restored_jobs=3"
      assert_includes output, "snapshot=#{snapshot_id}"
    end
  end

  def test_command_rejects_unknown_and_malformed_registered_projects
    unknown = Hive::Commands::RefactorPatrolSchemaRestore.new(
      "missing",
      "snapshot-#{"c" * 64}",
      project_resolver: ->(*) { nil },
      restorer: ->(*) { flunk "unknown registration reached restore" }
    )
    error = assert_raises(Hive::ConfigError) { unknown.call }
    assert_match(/unknown project "missing"/, error.message)

    malformed = Hive::Commands::RefactorPatrolSchemaRestore.new(
      "broken",
      "snapshot-#{"d" * 64}",
      project_resolver: ->(*) { { "name" => "broken" } },
      restorer: ->(*) { flunk "malformed registration reached restore" }
    )
    error = assert_raises(Hive::ConfigError) { malformed.call }
    assert_match(/registered project identity is unavailable/, error.message)
    assert_match(/KeyError/, error.message)
  end

  def test_cli_route_constructs_the_restore_command
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call) { calls << :call }

    with_replaced_singleton_method(
      Hive::Commands::RefactorPatrolSchemaRestore,
      :new,
      ->(project, snapshot_id, json:) {
        calls << [ project, snapshot_id, json ]
        fake
      }
    ) do
      Hive::CLI.start([
        "refactor-patrol-schema-restore", "demo",
        "snapshot-#{"e" * 64}", "--json"
      ])
    end

    assert_equal(
      [
        [ "demo", "snapshot-#{"e" * 64}", true ],
        :call
      ],
      calls
    )
  end
end
