require "test_helper"
require "hive/commands/runtime"
require "json_schemer"

class RuntimeCommandTest < Minitest::Test
  include HiveTestHelper

  def test_status_is_typed_and_does_not_create_a_missing_database
    with_tmp_dir do |root|
      output = StringIO.new

      result = Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: root, projects: []
      ).call

      assert_equal 0, result
      payload = JSON.parse(output.string)
      assert_equal "hive-runtime-maintenance", payload.fetch("schema")
      assert_equal 1, payload.fetch("schema_version")
      assert_equal "absent", payload.dig("result", "phase")
      assert_equal "missing", payload.dig("result", "database", "status")
      assert_empty runtime_schema.validate(payload).to_a
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_json_failure_is_versioned_typed_and_actionable
    with_tmp_dir do |root|
      current = File.join(root, ".runtime-cutover", "current")
      FileUtils.mkdir_p(current)
      manifest = File.join(current, "active.json")
      File.binwrite(manifest, "{\n")
      File.chmod(0o600, manifest)
      output = StringIO.new

      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::IntegrityError) do
        Hive::Commands::Runtime.new(
          "status", json: true, output: output, state_home: root, projects: []
        ).call
      end
      payload = JSON.parse(output.string)

      assert_equal :manifest_corrupt, error.code
      assert_equal false, payload.fetch("ok")
      assert_equal "status", payload.fetch("action")
      assert_equal "manifest_corrupt", payload.fetch("runtime_code")
      assert_kind_of String, payload.fetch("next_action")
      assert_empty runtime_schema.validate(payload).to_a
    end
  end

  def test_status_fails_closed_on_a_corrupt_active_manifest
    with_tmp_dir do |root|
      current = File.join(root, ".runtime-cutover", "current")
      FileUtils.mkdir_p(current)
      manifest = File.join(current, "active.json")
      File.binwrite(manifest, "{\n")
      File.chmod(0o600, manifest)

      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::IntegrityError) do
        Hive::Commands::Runtime.new(
          "status", output: StringIO.new, state_home: root, projects: []
        ).call
      end

      assert_equal :manifest_corrupt, error.code
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_status_reports_an_intended_cutover_as_forward_resumable
    with_tmp_dir do |root|
      state = File.join(root, "state")
      data = File.join(root, "data")
      services = Struct.new(:activated) do
        def stop!(**) = true
        def activate! = self.activated = true
        def activated? = !!activated
      end.new(false)
      crash = Class.new(StandardError)
      cutover = Hive::RuntimeControlPlane::Cutover.new(
        state_home: state, data_home: data, projects: [], services: services,
        fault: ->(point) { raise crash if point == :activation_intent }
      )
      assert_raises(crash) { cutover.bootstrap(confirm: true) }
      output = StringIO.new

      assert_equal 0, Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: state, projects: []
      ).call
      payload = JSON.parse(output.string)
      assert_equal "intended", payload.dig("result", "phase")
      assert_equal "hive runtime resume", payload.dig("result", "next_action")
      assert_empty runtime_schema.validate(payload).to_a
    end
  end

  def test_resume_dispatches_the_forward_cutover_and_returns_typed_output
    result = Hive::RuntimeControlPlane::Cutover::Result.new(
      "active", "cutover-1", "/tmp/runtime.sqlite3", []
    )
    captured = nil
    output = StringIO.new
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::Cutover, :resume,
      ->(**options) { captured = options; result }
    ) do
      assert_equal 0, Hive::Commands::Runtime.new(
        "resume", json: true, output: output, state_home: "/tmp/state", projects: [ "project" ]
      ).call
    end

    assert_equal "/tmp/state", captured.fetch(:state_home)
    assert_equal [ "project" ], captured.fetch(:projects)
    payload = JSON.parse(output.string)
    assert_equal "resume", payload.fetch("action")
    assert_equal "active", payload.dig("result", "phase")
    assert_empty runtime_schema.validate(payload).to_a
  end

  def test_removed_recovery_actions_are_rejected_before_any_database_write
    with_tmp_dir do |root|
      %w[snapshot backup restore downgrade].each do |action|
        error = assert_raises(Hive::UsageError) do
          Hive::Commands::Runtime.new(
            action, output: StringIO.new, state_home: root, projects: []
          ).call
        end
        assert_includes error.message, "status or resume"
      end
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  private

  def runtime_schema
    JSONSchemer.schema(JSON.parse(File.read(
      Hive::Schemas.schema_path("hive-runtime-maintenance")
    )))
  end
end
