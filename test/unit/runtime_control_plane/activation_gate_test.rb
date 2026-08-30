require "test_helper"
require "hive/runtime_control_plane/activation_gate"

class RuntimeControlPlaneActivationGateTest < Minitest::Test
  include HiveTestHelper

  def test_ordinary_route_is_refused_before_any_startup_callback
    with_tmp_dir do |root|
      state = File.join(root, "state")
      FileUtils.mkdir_p(state)
      File.binwrite(File.join(state, "task-counter.yml"), "---\ngeneration: 4\n")
      callbacks = []

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "status" ], state_home: state, config_home: File.join(root, "config"),
          before_allow: -> { callbacks << :startup_mutation }
        )
      end

      assert_equal :fleet_cutover_required, error.code
      assert_equal "hive migrate --all --yes", error.action
      assert_empty callbacks
    end
  end

  def test_only_forward_maintenance_routes_are_admitted_while_inactive
    with_tmp_dir do |root|
      state = File.join(root, "state")
      FileUtils.mkdir_p(File.join(state, ".runtime-cutover", "current"))
      config = File.join(root, "config")

      [
        [ "migrate", "--all" ], [ "runtime", "status" ], [ "runtime", "resume" ],
        [ "doctor" ], [ "--version" ], [ "version" ]
      ].each do |argv|
        assert Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: argv, state_home: state, config_home: config
        ), argv.join(" ")
      end
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "runtime", "backup" ], state_home: state, config_home: config
        )
      end
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "setup" ], state_home: state, config_home: config
        )
      end
    end
  end

  def test_fresh_setup_is_admitted_only_without_legacy_or_cutover_state
    with_tmp_dir do |root|
      assert Hive::RuntimeControlPlane::ActivationGate.check!(
        argv: [ "setup" ], state_home: File.join(root, "state"),
        config_home: File.join(root, "config")
      )
    end
  end

  def test_executable_checks_activation_before_loading_or_reconciling_the_wiki
    source = File.binread(File.expand_path("../../../bin/hive", __dir__))

    gate = source.index("ActivationGate.check!")
    wiki_require = source.index('require "hive/llm_wiki_bootstrap"')
    reconcile = source.index("Scheduler.reconcile_existing!")
    assert gate < wiki_require
    assert gate < reconcile
  end
end
