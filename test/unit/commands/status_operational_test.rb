require "test_helper"
require "json_schemer"
require "hive/commands/status"

class CommandsStatusOperationalTest < Minitest::Test
  include HiveTestHelper

  def test_operational_payload_is_additive_and_keeps_legacy_status_v6_unchanged
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "2-brainstorm", "ready-260720-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true, operational: true)

      legacy = command.json_payload([ project ])
      operational = command.operational_payload([ project ])

      assert_equal "hive-status", legacy.fetch("schema")
      assert_equal 6, legacy.fetch("schema_version")
      assert_equal "hive-operational-status", operational.fetch("schema")
      assert_equal [ "ready-260720-abcd" ], legacy.dig("projects", 0, "tasks").map { |row| row.fetch("slug") }
      assert_equal [ "ready-260720-abcd" ], operational.fetch("tasks").map { |row| row.dig("identity", "slug") }
      refute operational.fetch("tasks").first.fetch("evidence").key?("suggested_command")
    end
  end

  def test_operational_json_call_emits_the_operational_envelope
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      FileUtils.mkdir_p(File.join(hive_state, "stages"))

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        stdout, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
        payload = JSON.parse(stdout)
        schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))

        assert_equal "hive-operational-status", payload.fetch("schema")
        assert schema.valid?(payload), schema.validate(payload).map { |error| error.fetch("error") }.inspect
      end
    end
  end

  def test_operational_recoveries_uses_the_same_canonical_recovery_projection
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-review", "failed-260725-abcd")
      FileUtils.mkdir_p(folder)
      File.write(
        File.join(folder, "review.md"),
        <<~MARKDOWN
          # Review
          <!-- REVIEW_ERROR marker_id=recovery-1 reason=review_failed phase=review pass=1 -->
        MARKDOWN
      )
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true)
      source = command.json_payload([ project ])

      full = command.operational_payload(
        [ project ],
        status_payload: source,
        scheduler_snapshot: nil
      )
      lean = command.operational_recoveries(
        [ project ],
        status_payload: source,
        scheduler_snapshot: nil
      )

      expected = full.fetch("tasks").filter_map do |row|
        next unless row["recovery"]

        {
          "identity" => row.fetch("identity").slice("project", "slug"),
          "recovery" => row.fetch("recovery")
        }
      end
      assert_equal expected, lean
    end
  end

  def test_operational_call_uses_its_own_error_schema
    command = Hive::Commands::Status.new(json: true, operational: true)

    assert_equal "hive-operational-status", command.status_schema_for_call
    assert_equal "hive-status", Hive::Commands::Status.new(json: true).status_schema_for_call
  end
end
