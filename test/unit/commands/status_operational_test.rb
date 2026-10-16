require "test_helper"
require "json_schemer"
require "hive/commands/status"

class CommandsStatusOperationalTest < Minitest::Test
  include HiveTestHelper

  def teardown
    Hive::RuntimeControlPlane::OperationalInspection.clear! if
      defined?(Hive::RuntimeControlPlane::OperationalInspection)
    super
  end

  def test_operational_payload_is_additive_and_keeps_current_status_v8_unchanged
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
      assert_equal 8, legacy.fetch("schema_version")
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

  def test_inspection_context_carries_through_uncached_operational_task_and_attempt_reads
    with_tmp_global_config do |state_home|
      with_tmp_dir do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        slug = "read-only-audit-261003-abcd"
        folder = File.join(hive_state, "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
        database = Struct.new(:path) do
          def confirmed_read_only_storage? = true
        end.new(Hive::Paths.runtime_control_plane_path(state_home))
        error = Hive::RuntimeControlPlane::Unavailable.new(
          "read only", code: :state_storage_read_only,
          action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
        )
        assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
          error: error, argv: %w[status --operational --json], state_home: state_home,
          database: database
        )

        with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
          stdout, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
          payload = JSON.parse(stdout)
          assert_equal true, payload.fetch("ok")
          assert_equal [ slug ], payload.fetch("tasks").map { |row| row.dig("identity", "slug") }
        end
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

  def test_supplied_status_payload_skips_workflow_generation_capture
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(
        File.join(hive_state, "config.yml"),
        { "daemon" => { "enabled" => true } }.to_yaml
      )
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true)
      source = command.json_payload([ project ])
      command.define_singleton_method(:capture_workflow_generations) do |_projects|
        raise "supplied payload must not trigger generation capture"
      end
      original_load = Hive::Config.method(:load)
      config_loads = 0

      payload = with_replaced_singleton_method(
        Hive::Config,
        :load,
        lambda do |path|
          config_loads += 1
          original_load.call(path)
        end
      ) do
        command.operational_payload(
          [ project ], status_payload: source, scheduler_snapshot: nil
        )
      end

      assert_equal "unavailable", payload.dig("scheduler", "status")
      assert_equal 1, config_loads
    end
  end

  def test_operational_call_uses_its_own_error_schema
    command = Hive::Commands::Status.new(json: true, operational: true)

    assert_equal "hive-operational-status", command.status_schema_for_call
    assert_equal "hive-running-status", Hive::Commands::Status.new(json: true).status_schema_for_call
  end

  def test_operational_storage_error_exposes_code_and_next_action_additively
    command = Hive::Commands::Status.new(json: true, operational: true)
    error = Hive::RuntimeControlPlane::Unavailable.new(
      "Hive state is mounted read-only",
      code: :state_storage_read_only,
      action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
    )
    command.define_singleton_method(:do_call) { raise error }

    stdout, _stderr, status = with_captured_exit { command.call }
    payload = JSON.parse(stdout)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))

    assert_equal Hive::ExitCodes::UNAVAILABLE, status
    assert_equal false, payload.fetch("ok")
    assert_equal "state_storage_read_only", payload.fetch("code")
    assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION,
                 payload.fetch("next_action")
    assert schema.valid?(payload), schema.validate(payload).map { |entry| entry.fetch("error") }.inspect
  end

  def test_storage_extras_do_not_leak_to_other_status_error_schemas
    error = Hive::RuntimeControlPlane::Unavailable.new(
      "Hive state is mounted read-only",
      code: :state_storage_read_only,
      action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
    )
    cases = [
      [ Hive::Commands::Status.new(json: true), "hive-running-status" ],
      [ Hive::Commands::Status.new(json: true, full: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, archive: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, daemon_tasks: [ "demo:task" ], full: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, diagnose: "task"), "hive-status-diagnose" ]
    ]

    cases.each do |command, schema_name|
      command.define_singleton_method(:do_call) { raise error }
      command.define_singleton_method(:diagnose_call) { raise error }
      stdout, _stderr, status = with_captured_exit { command.call }
      payload = JSON.parse(stdout)
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema_name))))

      assert_equal Hive::ExitCodes::UNAVAILABLE, status, schema_name
      refute payload.key?("code"), schema_name
      refute payload.key?("next_action"), schema_name
      assert schema.valid?(payload),
             "#{schema_name}: #{schema.validate(payload).map { |entry| entry.fetch('error') }.inspect}"
    end
  end

  def test_degraded_attempt_storage_renders_one_concise_warning
    issue = {
      "code" => "attempt_storage_degraded",
      "message" => "attempt storage is degraded: maintenance failed",
      "remediation" => "inspect the daemon log, then retry the failed storage operation"
    }

    out, = capture_io do
      Hive::Commands::Status.new.send(:render_operational_issues, [ issue ])
    end

    assert_equal 1, out.lines.size
    assert_includes out, "maintenance failed"
    assert_includes out, "inspect the daemon log"
  end
end
