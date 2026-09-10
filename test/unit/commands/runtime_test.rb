require "test_helper"
require "hive/commands/runtime"
require "json_schemer"
require "open3"

class RuntimeCommandTest < Minitest::Test
  include HiveTestHelper

  def test_status_is_typed_and_returns_nonzero_without_creating_missing_storage
    with_tmp_dir do |root|
      output = StringIO.new
      assert_equal 1, Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: root
      ).call
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "absent", payload.dig("result", "phase")
      assert_equal "missing", payload.dig("result", "database", "status")
      assert_equal "hive setup", payload.dig("result", "next_action")
      assert_empty runtime_schema.validate(payload).to_a
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_executable_reports_absent_runtime_with_nonzero_exit_and_false_ok
    with_tmp_dir do |root|
      [ %w[runtime status --json], %w[runtime --json status], %w[runtime --json] ].each do |argv|
        output, errors, process = Open3.capture3(
          { "HIVE_HOME" => root }, RbConfig.ruby,
          File.expand_path("../../../bin/hive", __dir__), *argv
        )
        assert_equal 1, process.exitstatus, errors
        payload = JSON.parse(output)
        assert_equal false, payload.fetch("ok")
        assert_equal "absent", payload.dig("result", "phase")
        assert_equal "hive setup", payload.dig("result", "next_action")
        assert_empty runtime_schema.validate(payload).to_a
        refute runtime_schema.valid?(payload.merge("ok" => true))
        refute_path_exists Hive::Paths.runtime_control_plane_path(root)
      end
    end
  end

  def test_json_failure_is_typed_and_actionable
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      File.write(path, "invalid", perm: 0o600)
      output = StringIO.new
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::Commands::Runtime.new("status", json: true, output: output, state_home: root).call
      end
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "status", payload.fetch("action")
      assert_kind_of String, payload.fetch("next_action")
      assert_empty runtime_schema.validate(payload).to_a
    end
  end

  def test_json_failure_supplies_a_next_action_when_the_runtime_error_has_none
    output = StringIO.new
    error = Hive::RuntimeControlPlane::IntegrityError.new(
      "broken", code: :broken, action: nil
    )

    with_replaced_singleton_method(Hive::RuntimeControlPlane::Installation, :status, ->(**) { raise error }) do
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::Commands::Runtime.new("status", json: true, output: output).call
      end
    end

    assert_equal "repair the reported runtime database, then run hive runtime status",
                 JSON.parse(output.string).fetch("next_action")
  end

  def test_status_uses_database_identity_without_manifests
    with_tmp_dir do |root|
      status = Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      output = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: root
      ).call
      payload = JSON.parse(output.string)
      assert_equal true, payload.fetch("ok")
      assert_equal status, payload.fetch("result")
      assert_empty runtime_schema.validate(payload).to_a
      text = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new("status", output: text, state_home: root).call
      assert_includes text.string, "phase: active"
    end
  end

  def test_removed_recovery_actions_are_rejected_before_any_database_write
    with_tmp_dir do |root|
      %w[resume snapshot backup restore downgrade].each do |action|
        error = assert_raises(Hive::UsageError) do
          Hive::Commands::Runtime.new(action, output: StringIO.new, state_home: root).call
        end
        assert_includes error.message, "expected status"
      end
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  private

  def runtime_schema
    JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-runtime-maintenance"))))
  end
end
