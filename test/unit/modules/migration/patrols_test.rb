require "test_helper"
require "hive/daemon/patrol_scheduler"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/modules/migration/patrols"
require "hive/modules/migration/coordinator"

class ModulesMigrationPatrolsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 12)

  class FakeStore
    attr_reader :restores

    def initialize
      @restores = []
      @selections = %w[patrol architecture-patrol].to_h do |name|
        marker = name == "patrol" ? "a" : "b"
        [ name, {
          "schema_version" => 1, "name" => name, "installed" => true, "enabled" => true,
          "epoch" => 2, "active" => identity(marker), "previous" => identity(marker.next),
          "high_water_at" => NOW.iso8601(6), "receipt_digest" => "f" * 64
        } ]
      end
    end

    def inspect_selection(name, include_tombstone: false) = @selections[name]
    def inspect_selections = @selections.values
    def configuration(_name, _digest) = true

    def restore_previous(name, expected_active:, now:)
      selection = @selections.fetch(name)
      raise "stale" unless selection.fetch("active") == expected_active
      @restores << [ name, now ]
      @selections[name] = selection.merge(
        "active" => selection.fetch("previous"), "previous" => selection.fetch("active"),
        "epoch" => selection.fetch("epoch") + 1
      )
    end

    private

    def identity(marker)
      {
        "version" => "0.1.0", "catalog_commit" => marker * 40,
        "source_commit" => marker * 40, "manifest_digest" => marker * 64,
        "configuration_digest" => marker * 64
      }
    end
  end

  Report = Data.define(:eligible?, :blockers, :configuration_digests)
  Scan = Data.define(:records, :invalid_records)

  class FakeSupervisor
    attr_accessor :live

    def initialize = @live = true
    def in_flight?(project:, stage:) = live && project == "demo" && stage == "patrol"
  end

  class FakeAttemptStore
    def scan = Scan.new(records: [], invalid_records: [])
  end

  def test_fences_live_adoption_then_cuts_over_and_rolls_back_one_epoch
    with_project do |project|
      store = FakeStore.new
      probe_state = :live
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { probe_state }
      )

      pending = migration.adopt!(now: NOW)
      assert_equal "pending", pending.status
      refute Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )

      probe_state = :quiescent
      shadowing = migration.adopt!(now: NOW + 60)
      assert_equal "shadowing", shadowing.status
      assert_equal "legacy", Hive::Modules::Migration::Patrols.owner_for(
        project.fetch("path"), "patrol", hive_state_path: project.fetch("hive_state_path")
      )
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "architecture-patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )

      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: {
          "patrol" => "a" * 64, "architecture-patrol" => "b" * 64
        }
      )
      cutover = migration.cutover!(report: report, now: NOW + 120)
      assert_equal "module", cutover.status
      assert_equal 2, cutover.state.fetch("epoch")
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :module,
        hive_state_path: project.fetch("hive_state_path")
      )
      watermarks = cutover.state.fetch("watermarks")

      rollback = migration.rollback!(now: NOW + 180)
      assert_equal "rolled_back", rollback.status
      assert_equal 3, rollback.state.fetch("epoch")
      assert_equal watermarks, rollback.state.fetch("watermarks")
      assert_equal %w[architecture-patrol patrol], store.restores.map(&:first).sort
      assert_equal({ "patrol" => "previous", "architecture-patrol" => "previous" }, rollback.restored)
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )
    end
  end

  def test_missing_state_preserves_legacy_and_corrupt_state_fails_closed
    with_project do |project|
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )
      path = Hive::Modules::Migration::Patrols.state_file(
        project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
      )
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{corrupt")

      refute Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )
      assert_equal :fenced, Hive::Modules::Migration::Patrols.module_mode(
        project.fetch("path"), "patrol", configured_shadow: false,
        hive_state_path: project.fetch("hive_state_path")
      )
    end
  end

  def test_legacy_schedulers_stop_before_config_or_claim_work_when_epoch_denies_admission
    entry = { "name" => "demo", "path" => "/project", "hive_state_path" => "/state" }
    denied = ->(_entry, _module_name, _authority) { false }
    config_loader = ->(_path) { raise "must not load fenced project config" }
    patrol = Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] }, config_loader: config_loader,
      migration_ownership: denied
    )
    architecture = Hive::Daemon::RefactorPatrolScheduler.new(
      registry: -> { [ entry ] }, config_loader: config_loader,
      migration_ownership: denied
    )

    assert_empty patrol.candidates(now: NOW)
    assert_empty architecture.candidates(now: NOW)
  end

  def test_daemon_coordinator_retries_fenced_adoption_after_exact_child_quiesces
    with_project do |project|
      store = FakeStore.new
      supervisor = FakeSupervisor.new
      coordinator = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor, attempt_store: FakeAttemptStore.new,
        registry: -> { [ project ] }, store_factory: ->(_state) { store }
      )

      first = coordinator.tick(now: NOW).fetch(0)
      assert_equal :pending, first.fetch(:status)
      assert_equal({ "patrol" => "live" }, first.fetch(:blockers))

      supervisor.live = false
      second = coordinator.tick(now: NOW + 30).fetch(0)
      assert_equal :shadowing, second.fetch(:status)
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )
      assert_empty coordinator.tick(now: NOW + 60)
    end
  end

  private

  def with_project
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      yield({ "name" => "demo", "path" => root, "hive_state_path" => state })
    end
  end
end
