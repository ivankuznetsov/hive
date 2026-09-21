require "test_helper"
require "hive/runtime_control_plane/activation_gate"
require "open3"

class RuntimeControlPlaneActivationGateTest < Minitest::Test
  include HiveTestHelper

  def test_fresh_commands_remain_available_without_creating_storage
    with_tmp_dir do |root|
      %w[setup help init].each do |route|
        assert Hive::RuntimeControlPlane::ActivationGate.check!(argv: [ route ], state_home: root)
      end
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_existing_invalid_database_blocks_startup_but_allows_diagnosis
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      File.write(path, "invalid", perm: 0o600)
      callbacks = []
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "status" ], state_home: root, before_allow: -> { callbacks << :mutation }
        )
      end
      assert_empty callbacks
      [
        %w[runtime], %w[runtime --json], %w[runtime status],
        %w[runtime status --json], %w[runtime --json status], %w[--json runtime status],
        %w[doctor], %w[setup], %w[--version]
      ].each do |argv|
        assert Hive::RuntimeControlPlane::ActivationGate.check!(argv: argv, state_home: root)
      end
      assert_equal "invalid", File.read(path)
      refute Hive::RuntimeControlPlane::ActivationGate.active?(root)
    end
  end

  def test_current_database_admits_startup_without_cutover_evidence
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      callbacks = []
      assert Hive::RuntimeControlPlane::ActivationGate.check!(
        argv: %w[daemon start], state_home: root, before_allow: -> { callbacks << :allowed }
      )
      assert_equal [ :allowed ], callbacks
      assert Hive::RuntimeControlPlane::ActivationGate.active?(root)
    end
  end

  def test_executable_reports_corrupt_storage_as_typed_json
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      File.write(path, "invalid", perm: 0o600)
      output, errors, process = Open3.capture3(
        { "HIVE_HOME" => root }, RbConfig.ruby,
        File.expand_path("../../../bin/hive", __dir__), "status", "--json"
      )
      assert_equal Hive::ExitCodes::SOFTWARE, process.exitstatus
      payload = JSON.parse(output)
      assert_equal "hive-runtime-maintenance", payload.fetch("schema")
      assert_equal false, payload.fetch("ok")
      assert_equal "status", payload.fetch("action")
      assert_equal "database_corrupt", payload.fetch("runtime_code")
      assert_equal Hive::RuntimeControlPlane::Database::BACKUP_ACTION, payload.fetch("next_action")
      assert_includes errors, "hive: next action:"
      refute_includes errors, "Traceback"
      assert_equal "invalid", File.read(path)
    end
  end

  def test_executable_checks_database_before_loading_or_reconciling_the_wiki
    source = File.binread(File.expand_path("../../../bin/hive", __dir__))
    gate = source.index("ActivationGate.check!")
    assert gate < source.index('require "hive/llm_wiki_bootstrap"')
    assert gate < source.index("Scheduler.reconcile_existing!")
  end
end
