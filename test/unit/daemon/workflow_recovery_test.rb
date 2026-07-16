require "test_helper"
require "hive/daemon/status_consumer"
require "hive/daemon/workflow_recovery"
require "hive/provider_routing/store"

class DaemonWorkflowRecoveryTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row
  FakeAdapter = Struct.new(:snapshot_value, :configuration, keyword_init: true) do
    def snapshot(row:, project_root:, config:)
      _ = [ row, project_root, config ]
      snapshot_value
    end

    def configuration_for(child:, row:, config:)
      _ = [ child, row, config ]
      configuration
    end

    def resume_command(row:, snapshot:)
      _ = snapshot
      "hive run #{row.slug}"
    end
  end

  FakeRegistry = Struct.new(:adapter) do
    def resolve(_workflow) = adapter
  end

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_claims_one_outer_resume_per_workflow_generation_across_restart
    with_tmp_dir do |dir|
      leases = Hive::AttemptLeaseStore.new(path: File.join(dir, "leases.json"), clock: -> { NOW })
      circuits = Hive::ProviderRouting::Store.new(path: File.join(dir, "circuits.json"), clock: -> { NOW })
      router = Hive::ProviderRouting::Router.new(circuit_store: circuits, lease_store: leases, clock: -> { NOW })
      adapter = FakeAdapter.new(snapshot_value: snapshot(7), configuration: configuration)

      first = coordinator(router, leases, adapter).candidates([ row ], now: NOW)
      assert_equal 1, first.length
      coordinator(router, leases, adapter).finish(first.first, dispatched: true, now: NOW)

      restarted = coordinator(router, leases, adapter).candidates([ row ], now: NOW)
      assert_empty restarted
      assert_equal "completed", leases.leases(namespace: Hive::AttemptLeaseStore::RECOVERY_NAMESPACE).first.state
    end
  end

  def test_blocked_outer_spawn_releases_generation_for_a_later_tick
    with_tmp_dir do |dir|
      leases = Hive::AttemptLeaseStore.new(path: File.join(dir, "leases.json"), clock: -> { NOW })
      router = Hive::ProviderRouting::Router.new(
        circuit_store: Hive::ProviderRouting::Store.new(path: File.join(dir, "circuits.json"), clock: -> { NOW }),
        lease_store: leases,
        clock: -> { NOW }
      )
      adapter = FakeAdapter.new(snapshot_value: snapshot(2), configuration: configuration)
      recovery = coordinator(router, leases, adapter)

      attempt = recovery.candidates([ row ], now: NOW).first
      recovery.finish(attempt, dispatched: false, now: NOW)

      assert_equal 1, recovery.candidates([ row ], now: NOW).length
    end
  end

  def test_rejects_same_generation_with_a_changed_fingerprint
    events = []
    logger = Object.new
    logger.define_singleton_method(:event) { |kind, **payload| events << [ kind, payload ] }
    with_tmp_dir do |dir|
      leases = Hive::AttemptLeaseStore.new(path: File.join(dir, "leases.json"), clock: -> { NOW })
      router = Hive::ProviderRouting::Router.new(
        circuit_store: Hive::ProviderRouting::Store.new(path: File.join(dir, "circuits.json"), clock: -> { NOW }),
        lease_store: leases, clock: -> { NOW }
      )
      adapter = FakeAdapter.new(snapshot_value: snapshot(3, fingerprint: "sha256:one"), configuration: configuration)
      recovery = coordinator(router, leases, adapter, logger: logger)
      first = recovery.candidates([ row ], now: NOW).first
      recovery.finish(first, dispatched: false, now: NOW)
      adapter.snapshot_value = snapshot(3, fingerprint: "sha256:two")

      assert_empty recovery.candidates([ row ], now: NOW)
      assert_equal :workflow_recovery_error, events.last.first
      assert_includes events.last.last.fetch(:message), "without advancing generation"
    end
  end

  private

  def coordinator(router, leases, adapter, logger: nil)
    Hive::Daemon::WorkflowRecovery.new(
      router: router,
      lease_store: leases,
      project_resolver: ->(_name) { { "path" => "/project" } },
      config_loader: ->(_root) { {} },
      workflow_resolver: ->(_name, _root) { Object.new },
      registry: FakeRegistry.new(adapter),
      logger: logger
    )
  end

  def row
    Row.new(
      project: "demo", slug: "campaign", stage: "2-run", workflow: "campaign",
      folder: "/project/.hive-state/stages/2-run/campaign", state_file: "/tmp/task.md",
      state_file_mtime: NOW, action: "error", suggested_command: "hive run campaign",
      live_task_lock: false
    )
  end

  def snapshot(generation, fingerprint: nil)
    Hive::ResumableWorkflow::Snapshot.new(
      workflow_id: "demo/campaign", kind: "campaign",
      checkpoint_generation: generation,
      checkpoint_fingerprint: fingerprint,
      children: [ { "child_id" => "pending", "status" => "pending" } ]
    )
  end

  def configuration
    Hive::ProviderRouting::Configuration.single(provider: "claude", agent: "claude")
  end
end
