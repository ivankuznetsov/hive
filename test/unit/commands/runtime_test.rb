require "test_helper"
require "hive/commands/runtime"

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
      assert_equal "absent", payload.dig("result", "phase")
      assert_equal "missing", payload.dig("result", "database", "status")
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
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
end
