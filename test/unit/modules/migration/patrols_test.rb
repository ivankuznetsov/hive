require "test_helper"
require "hive/daemon/patrol_scheduler"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/modules/migration/patrols"
require "hive/modules/migration/coordinator"
require "hive/patrol/state_store"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/transition_gateway"

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

  class ConfiguredAttemptStore
    def initialize(scan) = @scan = scan
    def scan = @scan
  end

  class SequencedAttemptStore
    attr_reader :calls

    def initialize(*scans)
      @scans = scans
      @calls = 0
    end

    def scan
      value = @scans.fetch([ @calls, @scans.length - 1 ].min)
      @calls += 1
      value
    end
  end

  Attempt = Struct.new(:project, :module_name, :finished) do
    def final? = finished
    def module_hook? = true
    def subject = { "module" => module_name }
    def [](key) = key == "project" ? project : nil
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
      assert_equal :shadow, Hive::Modules::Migration::Patrols.module_mode(
        project.fetch("path"), "patrol", configured_shadow: false,
        hive_state_path: project.fetch("hive_state_path")
      )
      assert_equal "legacy", Hive::Modules::Migration::Patrols.owner_for(
        project.fetch("path"), "patrol", hive_state_path: project.fetch("hive_state_path")
      )
      assert Hive::Modules::Migration::Patrols.admission_allowed?(
        project.fetch("path"), "architecture-patrol", authority: :legacy,
        hive_state_path: project.fetch("hive_state_path")
      )
      assert_match(/report\.json\z/, Hive::Modules::Migration::Patrols.report_file(
        project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
      ))

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
      assert_equal :fenced, Hive::Modules::Migration::Patrols.module_mode(
        project.fetch("path"), "patrol", configured_shadow: false,
        hive_state_path: project.fetch("hive_state_path")
      )
      assert_equal Hive::Config.load(project.fetch("path")),
                   Hive::Modules::Migration::Patrols.reviewed_config(
                     project.fetch("path"), "patrol",
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
      assert_equal "none", Hive::Modules::Migration::Patrols.owner_for(
        project.fetch("path"), "patrol", hive_state_path: project.fetch("hive_state_path")
      )
    end
  end

  def test_diagnostic_reviewed_configuration_and_admission_lock_reflect_durable_state
    with_project do |project|
      root = project.fetch("path")
      state_path = project.fetch("hive_state_path")
      assert_equal(
        {
          "status" => "unadopted", "owner" => "legacy", "admission" => false
        },
        Hive::Modules::Migration::Patrols.diagnostic(
          root, "patrol", hive_state_path: state_path
        )
      )

      migration = Hive::Modules::Migration::Patrols.new(
        project_root: root, project: "demo", hive_state_path: state_path,
        module_store: FakeStore.new, quiescence_probe: ->(*) { :quiescent }
      )
      migration.adopt!(now: NOW)
      diagnostic = Hive::Modules::Migration::Patrols.diagnostic(
        root, "patrol", hive_state_path: state_path
      )
      assert_equal "shadowing", diagnostic.fetch("status")
      assert_equal "legacy", diagnostic.fetch("owner")
      assert diagnostic.fetch("admission")
      reviewed = Hive::Modules::Migration::Patrols.reviewed_config(
        root, "patrol", hive_state_path: state_path
      )
      assert_equal ".hive-state", reviewed.fetch("hive_state_path")
      assert_equal root, reviewed.fetch("project_root")
      allowed = Hive::Modules::Migration::Patrols.with_admission(
        root, "patrol", authority: :legacy, hive_state_path: state_path
      ) { |admission| admission }
      assert allowed

      path = Hive::Modules::Migration::Patrols.state_file(
        root, hive_state_path: state_path
      )
      state = JSON.parse(File.binread(path))
      state["bindings"]["patrol"]["reviewed_config_digest"] = "0" * 64
      File.write(path, Hive::Modules::Migration::Patrols.canonical(state))
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Patrols.reviewed_config(
          root, "patrol", hive_state_path: state_path
        )
      end

      File.write(path, "{bad")
      corrupt = Hive::Modules::Migration::Patrols.diagnostic(
        root, "patrol", hive_state_path: state_path
      )
      assert_equal "corrupt", corrupt.fetch("status")
      assert_equal "none", corrupt.fetch("owner")
      refute corrupt.fetch("admission")
      refute_empty corrupt.fetch("blocker")
    end
  end

  def test_rollback_rejects_an_unrecognized_active_generation
    with_project do |project|
      store = FakeStore.new
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(*) { :quiescent }
      )
      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: {
          "patrol" => "a" * 64, "architecture-patrol" => "b" * 64
        }
      )
      migration.adopt!(now: NOW)
      migration.cutover!(report: report, now: NOW + 1)
      store.instance_variable_get(:@selections).fetch("patrol")["active"] = {
        "version" => "9.9.9", "catalog_commit" => "z" * 40,
        "source_commit" => "z" * 40, "manifest_digest" => "9" * 64,
        "configuration_digest" => "9" * 64
      }

      error = assert_raises(Hive::ConfigError) do
        migration.rollback!(now: NOW + 2)
      end
      assert_match(/active generation changed/, error.message)
    end
  end

  def test_reservation_rechecks_ownership_after_candidate_enumeration
    entry = { "name" => "demo", "path" => "/project", "hive_state_path" => "/state" }
    checks = 0
    ownership = lambda do |_entry, _module_name, _authority|
      checks += 1
      checks == 1
    end
    state_store = Object.new
    state_store.define_singleton_method(:recovery_backoff) do |now:|
      now
      { "generation" => 0, "failure" => nil, "blocked" => false }
    end
    state_store.define_singleton_method(
      :each_recovery_active_occurrence
    ) { |&| nil }
    state_store.define_singleton_method(
      :clear_recovery_failure!
    ) { |expected_generation:| expected_generation.zero? }
    scheduler = Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) {
        Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          "patrol" => { "enabled" => true, "trigger" => "timer", "poll_interval_sec" => 60 }
        )
      },
      migration_ownership: ownership,
      state_store_factory: ->(_candidate) { state_store }
    )

    candidate = scheduler.candidates(now: NOW).fetch(0)
    assert_nil scheduler.reserve(candidate, now: NOW)
    refute scheduler.pending?("demo")
  end

  def test_partial_two_module_rollback_is_resumable
    with_project do |project|
      store = FakeStore.new
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(*) { :quiescent }
      )
      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: {
          "patrol" => "a" * 64, "architecture-patrol" => "b" * 64
        }
      )
      migration.adopt!(now: NOW)
      migration.cutover!(report: report, now: NOW + 1)
      original = store.method(:restore_previous)
      failed_once = false
      store.define_singleton_method(:restore_previous) do |name, **options|
        if name == "architecture-patrol" && !failed_once
          failed_once = true
          raise Hive::ConfigError, "injected restore failure"
        end
        original.call(name, **options)
      end

      assert_raises(Hive::ConfigError) { migration.rollback!(now: NOW + 2) }
      resumed = migration.rollback!(now: NOW + 3)

      assert_equal "rolled_back", resumed.status
      assert_equal "already_restored", resumed.restored.fetch("patrol")
      assert_equal "previous", resumed.restored.fetch("architecture-patrol")
    end
  end

  def test_cutover_rebuilds_current_shadow_evidence_instead_of_trusting_saved_eligible
    with_project do |project|
      store = FakeStore.new
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(*) { :quiescent }
      )
      migration.adopt!(now: NOW)
      report = Struct.new(:payload) do
        def eligible? = true
        def blockers = []
        def configuration_digests
          { "patrol" => "a" * 64, "architecture-patrol" => "b" * 64 }
        end
      end.new(
        {
          "reviewer" => "reviewer-1",
          "reviewed_at" => NOW.iso8601(6)
        }
      )

      error = assert_raises(Hive::ConfigError) do
        migration.cutover!(report: report, now: NOW + 1)
      end
      assert_match(/evidence is stale/, error.message)
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

  def test_default_coordinator_probe_distinguishes_empty_and_active_ordinary_journals
    with_project do |project|
      supervisor = FakeSupervisor.new
      supervisor.live = false
      empty = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor,
        attempt_store: FakeAttemptStore.new,
        registry: -> { [ project ] },
        store_factory: ->(_state) { FakeStore.new }
      ).tick(now: NOW).fetch(0)

      assert_equal :shadowing, empty.fetch(:status)
      assert_empty empty.fetch(:blockers)
    end

    with_project do |project|
      state_store = Hive::Patrol::StateStore.new(project.fetch("path"))
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: {
          "project_id" => "project-1",
          "name" => "demo",
          "repository" => nil
        },
        trigger: {
          "kind" => "schedule",
          "id" => "tick-1",
          "schedule" => "ordinary",
          "occurred_at" => NOW.iso8601(6)
        },
        reservation: { "kind" => "ordinary", "id" => "reservation-1" },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "operation",
          "operation" => "coordinator-proof"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "patrol",
            rationale: "due"
          ),
        outcome_class: nil,
        outcome: nil,
        occurred_at: NOW,
        recorded_at: NOW
      )
      state_store.reserve_occurrence!(capture, now: NOW)
      supervisor = FakeSupervisor.new
      supervisor.live = false
      active = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor,
        attempt_store: FakeAttemptStore.new,
        registry: -> { [ project ] },
        store_factory: ->(_state) { FakeStore.new }
      ).tick(now: NOW).fetch(0)

      assert_equal :pending, active.fetch(:status)
      assert_equal({ "patrol" => "live" }, active.fetch(:blockers))
    end
  end

  def test_coordinator_blocks_invalid_attempt_state_and_live_module_attempts
    with_project do |project|
      store = FakeStore.new
      supervisor = FakeSupervisor.new
      supervisor.live = false
      invalid = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor,
        attempt_store: ConfiguredAttemptStore.new(Scan.new(records: [], invalid_records: [ "bad" ])),
        registry: -> { [ project ] }, store_factory: ->(_state) { store }
      ).tick(now: NOW).fetch(0)
      assert_equal({ "patrol" => "ambiguous", "architecture-patrol" => "ambiguous" }, invalid.fetch(:blockers))

      FileUtils.rm_f(Hive::Modules::Migration::Patrols.state_file(
        project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
      ))
      live_attempt = Attempt.new("demo", "patrol", false)
      active = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor,
        attempt_store: ConfiguredAttemptStore.new(Scan.new(records: [ live_attempt ], invalid_records: [])),
        registry: -> { [ project ] }, store_factory: ->(_state) { store }
      ).tick(now: NOW).fetch(0)
      assert_equal({ "patrol" => "live" }, active.fetch(:blockers))
    end
  end

  def test_coordinator_rechecks_attempts_for_each_quiescence_decision
    with_project do |project|
      store = FakeStore.new
      supervisor = FakeSupervisor.new
      supervisor.live = false
      live_attempt = Attempt.new("demo", "architecture-patrol", false)
      attempt_store = SequencedAttemptStore.new(
        Scan.new(records: [], invalid_records: []),
        Scan.new(records: [ live_attempt ], invalid_records: [])
      )
      result = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor, attempt_store: attempt_store,
        registry: -> { [ project ] }, store_factory: ->(_state) { store }
      ).tick(now: NOW).fetch(0)

      assert_equal :pending, result.fetch(:status)
      assert_equal({ "architecture-patrol" => "live" }, result.fetch(:blockers))
      assert_equal 2, attempt_store.calls
    end
  end

  def test_coordinator_blocks_ownership_epoch_on_durable_product_work
    with_project do |project|
      store = FakeStore.new
      supervisor = FakeSupervisor.new
      supervisor.live = false
      durable = {
        "patrol" => :live,
        "architecture-patrol" => :live
      }
      probes = []
      coordinator = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor,
        attempt_store: FakeAttemptStore.new,
        registry: -> { [ project ] },
        store_factory: ->(_state) { store },
        durable_work_probe: lambda do |entry, module_name|
          probes << [ entry.fetch("name"), module_name ]
          durable.fetch(module_name)
        end
      )

      pending = coordinator.tick(now: NOW).fetch(0)

      assert_equal :pending, pending.fetch(:status)
      assert_equal(
        {
          "patrol" => "live",
          "architecture-patrol" => "live"
        },
        pending.fetch(:blockers)
      )
      assert_equal(
        [
          [ "demo", "patrol" ],
          [ "demo", "architecture-patrol" ]
        ],
        probes
      )
    end
  end

  def test_default_coordinator_probe_observes_real_durable_product_work
    with_project do |project|
      state = Hive::Patrol::StateStore.new(project.fetch("path"))
      state.reserve_occurrence!(patrol_capture, now: NOW)

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :pending, result.fetch(:status)
      assert_equal({ "patrol" => "live" }, result.fetch(:blockers))
    end

    with_project do |project|
      store = Hive::RefactorPatrol::JobStore.new(
        project.fetch("path"), project: project
      )
      manifest = architecture_manifest
      capture = architecture_capture(manifest)
      store.reserve_manifest_occurrence!(
        manifest, capture: capture, now: NOW
      )

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :pending, result.fetch(:status)
      assert_equal(
        { "architecture-patrol" => "live" },
        result.fetch(:blockers)
      )
    end

    with_project do |project|
      store = Hive::RefactorPatrol::JobStore.new(
        project.fetch("path"), project: project
      )
      256.times do |index|
        store.write_job!(architecture_job(index))
      end
      store.write_job!(
        architecture_job(
          999,
          "state" => "queued",
          "complete" => false,
          "analysis_sha" => nil,
          "zero_reason" => nil
        )
      )

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :pending, result.fetch(:status)
      assert_equal(
        { "architecture-patrol" => "live" },
        result.fetch(:blockers)
      )
    end
  end

  def test_durable_stores_and_coordinator_use_configured_relative_and_absolute_state_paths
    with_tmp_dir do |root|
      [ "var/hive-state", File.join(root, "absolute-hive-state") ].each do |configured|
        state_path = File.expand_path(configured, root)
        FileUtils.mkdir_p(state_path)
        File.write(
          File.join(state_path, "config.yml"),
          { "hive_state_path" => configured }.to_yaml
        )
        project = {
          "name" => "demo-#{File.basename(state_path)}",
          "path" => root,
          "hive_state_path" => state_path
        }

        patrol = Hive::Patrol::StateStore.new(
          root, hive_state_path: configured
        )
        assert_equal File.join(state_path, "patrol"), patrol.root
        patrol.reserve_occurrence!(patrol_capture, now: NOW)

        architecture = Hive::RefactorPatrol::JobStore.new(
          root, hive_state_path: configured
        )
        assert_equal File.join(state_path, "refactor_patrol", "v3"), architecture.root

        supervisor = FakeSupervisor.new
        supervisor.live = false
        result = Hive::Modules::Migration::Coordinator.new(
          supervisor: supervisor,
          attempt_store: FakeAttemptStore.new,
          registry: -> { [ project ] },
          store_factory: ->(_state) { FakeStore.new }
        ).tick(now: NOW).fetch(0)

        assert_equal :pending, result.fetch(:status)
        assert_equal({ "patrol" => "live" }, result.fetch(:blockers))
        refute Dir.exist?(File.join(root, ".hive-state", "patrol", "occurrences"))
      end
    end
  end

  def test_default_coordinator_probe_accepts_completed_state_and_fails_closed
    with_project do |project|
      store = Hive::Patrol::StateStore.new(project.fetch("path"))
      capture = patrol_capture
      store.reserve_occurrence!(capture, now: NOW)
      evidence_store = Object.new
      evidence_store.define_singleton_method(:append_capture) { |_capture| }
      store.finalize_occurrence!(
        capture: terminal_patrol_capture(capture),
        evidence_store: evidence_store,
        now: NOW
      )

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :shadowing, result.fetch(:status)
      assert_empty result.fetch(:blockers)
    end

    with_project do |project|
      Hive::RefactorPatrol::JobStore.new(
        project.fetch("path"), project: project
      ).write_job!(architecture_job(1))

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :shadowing, result.fetch(:status)
      assert_empty result.fetch(:blockers)
    end

    with_project do |project|
      store = Hive::RefactorPatrol::JobStore.new(
        project.fetch("path"), project: project
      )
      aggregate = architecture_job(1)
      store.write_job!(aggregate)
      File.write(
        File.join(store.root, "jobs", "#{aggregate.fetch('job_id')}.json"),
        "{"
      )

      result = default_coordinator(project).tick(now: NOW).fetch(0)

      assert_equal :pending, result.fetch(:status)
      assert_equal(
        { "architecture-patrol" => "ambiguous" },
        result.fetch(:blockers)
      )
    end
  end

  def test_coordinator_defaults_and_project_errors_are_bounded
    defaulted = Hive::Modules::Migration::Coordinator.new(
      supervisor: FakeSupervisor.new, attempt_store: FakeAttemptStore.new
    )
    assert_instance_of Hive::ModulePackage::ManagedStore,
                       defaulted.instance_variable_get(:@store_factory).call("/state")

    entry = { "name" => "broken", "hive_state_path" => "/state" }
    blocked = Hive::Modules::Migration::Coordinator.new(
      supervisor: FakeSupervisor.new, attempt_store: FakeAttemptStore.new,
      registry: -> { [ entry ] },
      store_factory: ->(_state) { raise Hive::ConfigError, "broken state" }
    ).tick(now: NOW).fetch(0)
    assert_equal :blocked, blocked.fetch(:status)
    assert_equal "broken", blocked.fetch(:project)
    assert_match(/broken state/, blocked.fetch(:reason))
  end


  def test_coordinator_resumes_cutover_and_rollback_pending_states
    with_project do |project|
      store = FakeStore.new
      probe = :quiescent
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { probe }
      )
      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: { "patrol" => "a" * 64, "architecture-patrol" => "b" * 64 }
      )
      migration.adopt!(now: NOW)
      probe = :live
      assert_equal "cutover_pending", migration.cutover!(report: report, now: NOW + 1).status

      supervisor = FakeSupervisor.new
      supervisor.live = false
      coordinator = Hive::Modules::Migration::Coordinator.new(
        supervisor: supervisor, attempt_store: FakeAttemptStore.new,
        registry: -> { [ project ] }, store_factory: ->(_state) { store }
      )
      with_replaced_singleton_method(Hive::Modules::Migration::Report, :load, ->(_path) { report }) do
        assert_equal :module, coordinator.tick(now: NOW + 2).fetch(0).fetch(:status)
      end

      rollback = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { :live }
      ).rollback!(now: NOW + 3)
      assert_equal "rollback_pending", rollback.status
      assert_equal :rolled_back, coordinator.tick(now: NOW + 4).fetch(0).fetch(:status)
    end
  end

  def test_migration_state_machine_rejects_stale_evidence_and_invalid_transitions
    with_project do |project|
      store = FakeStore.new
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { :quiescent }
      )
      first = migration.adopt!(now: NOW)
      assert_equal "shadowing", first.status
      assert_equal "already_current", migration.adopt!(now: NOW + 1).status

      invalid_report = Object.new
      error = assert_raises(Hive::ConfigError) do
        migration.cutover!(report: invalid_report, now: NOW + 2)
      end
      assert_match(/report_invalid/, error.message)

      stale = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: { "patrol" => "0" * 64, "architecture-patrol" => "b" * 64 }
      )
      assert_raises(Hive::ConfigError) { migration.cutover!(report: stale, now: NOW + 3) }
      assert_raises(Hive::ConfigError) { migration.rollback!(now: NOW + 4) }
    end
  end

  def test_rollback_requires_a_fresh_shadow_window_before_recutover
    with_project do |project|
      store = FakeStore.new
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(*) { :quiescent }
      )
      old_report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: {
          "patrol" => "a" * 64, "architecture-patrol" => "b" * 64
        }
      )
      migration.adopt!(now: NOW)
      migration.cutover!(report: old_report, now: NOW + 1)
      migration.rollback!(now: NOW + 2)

      assert_raises(Hive::ConfigError) do
        migration.cutover!(report: old_report, now: NOW + 3)
      end
      restarted = migration.adopt!(now: NOW + 4)

      assert_equal "shadowing", restarted.status
      assert_equal((NOW + 4).iso8601(6), restarted.state.fetch("shadow_started_at"))
      assert_empty restarted.state.fetch("cutover_selections")
      assert_empty restarted.state.fetch("watermarks")
      assert_raises(Hive::ConfigError) do
        migration.cutover!(report: old_report, now: NOW + 5)
      end
    end
  end

  def test_pending_transitions_and_invalid_installation_or_probe_fail_closed
    with_project do |project|
      store = FakeStore.new
      pending = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { :live }
      )
      assert_equal "pending", pending.adopt!(now: NOW).status
      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: { "patrol" => "a" * 64, "architecture-patrol" => "b" * 64 }
      )
      assert_raises(Hive::ConfigError) { pending.cutover!(report: report, now: NOW + 1) }
      assert_raises(Hive::ConfigError) { pending.rollback!(now: NOW + 1) }
    end

    with_project do |project|
      store = FakeStore.new
      store.instance_variable_get(:@selections).delete("patrol")
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store
      )
      assert_raises(Hive::ConfigError) { migration.adopt!(now: NOW) }
    end

    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { raise "unknown owner" }
      )
      assert_equal(
        { "patrol" => "ambiguous", "architecture-patrol" => "ambiguous" },
        migration.adopt!(now: NOW).blockers
      )
    end
  end

  def test_state_reader_rejects_noncanonical_and_structurally_invalid_documents
    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { :quiescent }
      )
      migration.adopt!(now: NOW)
      path = Hive::Modules::Migration::Patrols.state_file(
        project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
      )
      state = JSON.parse(File.binread(path))
      File.write(path, JSON.pretty_generate(state))
      assert_raises(Hive::ConfigError) { migration.read }

      File.write(path, Hive::Modules::Migration::Patrols.canonical(state.merge("owners" => nil)))
      assert_raises(Hive::ConfigError) { migration.read }
    end
  end

  def test_cutover_and_rollback_wait_for_quiescence_without_moving_ownership
    with_project do |project|
      store = FakeStore.new
      probe = :quiescent
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: store,
        quiescence_probe: ->(_name, _root) { probe }
      )
      migration.adopt!(now: NOW)
      report = Report.new(
        eligible?: true, blockers: [],
        configuration_digests: { "patrol" => "a" * 64, "architecture-patrol" => "b" * 64 }
      )

      probe = :live
      pending = migration.cutover!(report: report, now: NOW + 1)
      assert_equal "cutover_pending", pending.status
      assert_equal "legacy", pending.state.dig("owners", "patrol")
      refute pending.state.dig("admissions", "patrol")

      probe = :quiescent
      assert_equal "module", migration.cutover!(report: report, now: NOW + 2).status
      probe = :live
      rollback = migration.rollback!(now: NOW + 3)
      assert_equal "rollback_pending", rollback.status
      assert_equal "module", rollback.state.dig("owners", "patrol")
      refute rollback.state.dig("admissions", "patrol")
    end
  end

  def test_default_probe_and_unreadable_legacy_state_are_conservative
    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"), project: "demo",
        hive_state_path: project.fetch("hive_state_path"), module_store: FakeStore.new
      )
      assert_equal(
        { "patrol" => "ambiguous", "architecture-patrol" => "ambiguous" },
        migration.adopt!(now: NOW).blockers
      )
    end

    with_project do |project|
      legacy = File.join(project.fetch("hive_state_path"), "patrol")
      FileUtils.mkdir_p(legacy)
      File.chmod(0o000, legacy)
      begin
        migration = Hive::Modules::Migration::Patrols.new(
          project_root: project.fetch("path"), project: "demo",
          hive_state_path: project.fetch("hive_state_path"), module_store: FakeStore.new,
          quiescence_probe: ->(_name, _root) { :quiescent }
        )
        assert_raises(Hive::ConfigError) { migration.adopt!(now: NOW) }
      ensure
        File.chmod(0o700, legacy)
      end
    end
  end

  def test_ownership_snapshot_and_adoption_lock_fail_closed
    with_project do |project|
      state_path = Hive::Modules::Migration::Patrols.state_file(
        project.fetch("path"),
        hive_state_path: project.fetch("hive_state_path")
      )
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, "{bad")
      assert_equal(
        {
          "owner" => "none",
          "epoch" => 0,
          "admission" => false
        },
        Hive::Modules::Migration::Patrols.ownership_snapshot(
          project.fetch("path"),
          "patrol",
          hive_state_path: project.fetch("hive_state_path")
        )
      )
    end

    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"),
        project: "demo",
        hive_state_path: project.fetch("hive_state_path"),
        module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { :quiescent }
      )
      migration.define_singleton_method(:mutate) do |&_block|
        nil
      end
      error = assert_raises(Hive::ConfigError) do
        migration.adopt!(now: NOW)
      end
      assert_match(/admission is unavailable/, error.message)
    end
  end

  def test_adoption_rechecks_concurrent_state_after_inventory
    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"),
        project: "demo",
        hive_state_path: project.fetch("hive_state_path"),
        module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { :quiescent }
      )
      migration.define_singleton_method(
        :migrate_shadow_decisions!
      ) do
        send(:write, read.merge("status" => "shadowing"))
      end
      assert_equal "already_current", migration.adopt!(now: NOW).status
    end

    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"),
        project: "demo",
        hive_state_path: project.fetch("hive_state_path"),
        module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { :quiescent }
      )
      migration.define_singleton_method(
        :migrate_shadow_decisions!
      ) do
        send(:write, read.merge("status" => "rolled_back"))
      end
      error = assert_raises(Hive::ConfigError) do
        migration.adopt!(now: NOW)
      end
      assert_match(/changed during adoption/, error.message)
    end

    with_project do |project|
      probes = 0
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"),
        project: "demo",
        hive_state_path: project.fetch("hive_state_path"),
        module_store: FakeStore.new,
        quiescence_probe: lambda do |_name, _root|
          probes += 1
          probes <= 2 ? :quiescent : :live
        end
      )
      migration.define_singleton_method(
        :migrate_shadow_decisions!
      ) { nil }
      outcome = migration.adopt!(now: NOW)
      assert_equal "pending", outcome.status
      assert_equal(
        {
          "patrol" => "live",
          "architecture-patrol" => "live"
        },
        outcome.blockers
      )
    end
  end

  def test_existing_shadowing_module_and_rolled_back_states_upgrade_v1_shadow_decisions
    %w[shadowing module rolled_back].each do |status|
      with_project do |project|
        migration = Hive::Modules::Migration::Patrols.new(
          project_root: project.fetch("path"), project: "demo",
          hive_state_path: project.fetch("hive_state_path"), module_store: FakeStore.new,
          quiescence_probe: ->(_name, _root) { :quiescent }
        )
        adopted = migration.adopt!(now: NOW)
        original = adopted.state.merge("status" => status)
        migration.send(:write, original)

        shadow_root = File.join(
          project.fetch("hive_state_path"), "module-runtime", "migration", "shadow"
        )
        FileUtils.rm_rf(File.join(shadow_root, "migrations"))
        v1_path = File.join(shadow_root, "patrol", "#{'a' * 64}.json")
        FileUtils.mkdir_p(File.dirname(v1_path))
        File.binwrite(
          v1_path,
          Hive::WorkflowPackage::CanonicalJSON.generate(legacy_shadow_decision)
        )

        upgraded = migration.adopt!(now: NOW + 1)

        assert_equal "already_current", upgraded.status, status
        assert_equal status, upgraded.state.fetch("status"), status
        assert_equal original.fetch("admissions"), upgraded.state.fetch("admissions"), status
        assert_equal 2, JSON.parse(File.binread(v1_path)).fetch("schema_version"), status
        assert File.file?(File.join(
          shadow_root, "migrations", "shadow-decision-v2.json"
        )), status
      end
    end
  end

  def test_shadow_inventory_distinguishes_live_quiescence_failure
    with_project do |project|
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project.fetch("path"),
        project: "demo",
        hive_state_path: project.fetch("hive_state_path"),
        module_store: FakeStore.new,
        quiescence_probe: ->(_name, _root) { :live }
      )
      error = assert_raises(Hive::ConfigError) do
        migration.send(:migrate_shadow_decisions!)
      end
      assert_match(/requires quiescence/, error.message)
    end
  end

  private

  def default_coordinator(project)
    supervisor = FakeSupervisor.new
    supervisor.live = false
    Hive::Modules::Migration::Coordinator.new(
      supervisor: supervisor,
      attempt_store: FakeAttemptStore.new,
      registry: -> { [ project ] },
      store_factory: ->(_state) { FakeStore.new }
    )
  end

  def patrol_capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "acme/demo"
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "coordinator-proof"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )
  end

  def terminal_patrol_capture(capture)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: capture.module_name,
      project: capture.project,
      trigger: capture.trigger,
      reservation: capture.reservation,
      owner: capture.owner,
      owner_epoch: capture.owner_epoch,
      selection_input: capture.selection_input,
      selection: capture.selection,
      outcome_class: "completed",
      outcome: { "rationale" => "completed" },
      effect_ids: capture.effect_ids,
      occurred_at: capture.occurred_at,
      recorded_at: NOW
    )
  end

  def architecture_manifest
    Hive::RefactorPatrol::PrManifest.build(
      source: {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => NOW.iso8601
      },
      files: [
        { "path" => "lib/demo.rb", "status" => "modified" }
      ]
    )
  end

  def architecture_capture(manifest)
    Hive::RefactorPatrol::TransitionGateway.capture_for_manifest(
      manifest: manifest,
      project_id: "project-1",
      owner: "legacy",
      owner_epoch: 1,
      recorded_at: NOW
    )
  end

  def architecture_job(index, overrides = {})
    digest = Digest::SHA256.hexdigest("coordinator-job-#{index}")
    {
      "schema" => Hive::RefactorPatrol::JobStore::SCHEMA,
      "schema_version" =>
        Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      "job_id" => format("job-%03d", index),
      "occurrence_id" => "occ-#{digest}",
      "intake_transition_id" => "intent-#{digest}",
      "source" => {
        "url" => "https://github.com/acme/demo/pull/#{index + 1}",
        "number" => index + 1,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40
      },
      "analysis_sha" => "c" * 40,
      "policy" => {
        "discovery" => true,
        "auto_fix" => false,
        "issue_filing" => false
      },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [],
        "flagged" => [],
        "suppressed" => []
      },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => "no_mapped_slice",
      "attempts" => [],
      "actions" => [],
      "created_at" => NOW.iso8601,
      "updated_at" => NOW.iso8601
    }.merge(overrides)
  end

  def with_project
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      yield(
        {
          "name" => "demo",
          "project_id" => "project-1",
          "path" => root,
          "hive_state_path" => state
        }
      )
    end
  end

  def legacy_shadow_decision
    {
      "schema" => "hive-module-shadow-decision",
      "schema_version" => 1,
      "module" => "patrol",
      "decision_id" => "a" * 64,
      "trigger_digest" => "b" * 64,
      "occurred_at" => NOW.iso8601(6),
      "recorded_at" => (NOW + 1).iso8601(6),
      "evidence_source" => "legacy_mutator_capture",
      "configuration_digest" => "c" * 64,
      "comparable" => true,
      "legacy" => { "rationale" => "due" },
      "module_decision" => { "rationale" => "due" },
      "explained_differences" => [],
      "unexplained_differences" => [],
      "legacy_effects" => [ "legacy-effect" ],
      "module_effects" => [],
      "duplicate_effects" => []
    }
  end
end
