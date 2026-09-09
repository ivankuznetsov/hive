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

  def test_managed_service_waits_at_intended_until_active_is_published
    status = { "phase" => "intended", "database" => { "status" => "ok" } }
    probes = 0
    sleeps = []
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::ActivationGate, :runtime_status, ->(*) { status }
    ) do
      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::ActivationGate, :active?, ->(*) { (probes += 1) > 1 }
      ) do
        assert Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: %w[daemon start], state_home: "/tmp/state",
          config_home: "/tmp/config", sleeper: ->(seconds) { sleeps << seconds }
        )
      end
    end
    assert_equal [ 0.05 ], sleeps
  end

  def test_executable_checks_activation_before_loading_or_reconciling_the_wiki
    source = File.binread(File.expand_path("../../../bin/hive", __dir__))

    gate = source.index("ActivationGate.check!")
    wiki_require = source.index('require "hive/llm_wiki_bootstrap"')
    reconcile = source.index("Scheduler.reconcile_existing!")
    assert gate < wiki_require
    assert gate < reconcile
  end

  def test_active_manifest_does_not_admit_commands_when_database_is_unhealthy
    with_tmp_dir do |root|
      state = File.join(root, "state")
      path = Hive::Paths.runtime_control_plane_path(state)
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      identity = database.installation_identity
      database.disconnect
      manifest_path = File.join(state, ".runtime-cutover", "current", "active.json")
      Hive::RuntimeControlPlane::CutoverManifest.new(path: manifest_path).publish(
        Hive::RuntimeControlPlane::CutoverManifest.build(
          phase: "active", installation_id: identity.fetch(:installation_id),
          source_release: "old", target_release: "new",
          exclusions: [], task_authority: [], evidence: { "activation_epoch" => 0 }
        )
      )
      File.binwrite(path, "corrupt")

      refute Hive::RuntimeControlPlane::ActivationGate.active?(state)
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "status" ], state_home: state, data_home: File.join(root, "data"),
          config_home: File.join(root, "config")
        )
      end
    ensure
      database&.disconnect
    end
  end

  def test_active_probe_timeout_and_corrupt_registry_fail_closed
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::ActivationGate, :runtime_status, ->(*) { raise KeyError, "bad" }
    ) do
      refute Hive::RuntimeControlPlane::ActivationGate.active?("/state")
    end

    clocks = [ 0.0, Hive::RuntimeControlPlane::ActivationGate::SERVICE_ACTIVATION_WAIT_SEC ].each
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::ActivationGate, :active?, ->(*) { false }
    ) do
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.wait_for_active!(
          "/state", sleeper: ->(_) { }, monotonic_clock: -> { clocks.next }
        )
      end
      assert_equal :fleet_cutover_required, error.code
    end

    with_tmp_dir do |root|
      config = File.join(root, "config")
      FileUtils.mkdir_p(config)
      File.binwrite(File.join(config, "config.yml"), "registered_projects: [\n")
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: [ "status" ], state_home: File.join(root, "state"),
          data_home: File.join(root, "data"), config_home: config
        )
      end
    end
  end

  def test_default_service_wait_sleeper_is_exercised
    status = { "phase" => "intended", "database" => { "status" => "ok" } }
    probes = 0
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::ActivationGate, :runtime_status, ->(*) { status }
    ) do
      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::ActivationGate, :active?, ->(*) { (probes += 1) > 1 }
      ) do
        assert Hive::RuntimeControlPlane::ActivationGate.check!(
          argv: %w[daemon start], state_home: "/tmp/state", config_home: "/tmp/config"
        )
      end
    end
  end
end
