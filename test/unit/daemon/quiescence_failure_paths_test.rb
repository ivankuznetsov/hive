require "test_helper"
require "hive/daemon/quiescence"
require "hive/commands/daemon/service_installer"
require "hive/commands/web/service_installer"
require "hive/commands/bot/service_installer"
require "hive/commands/babysit/service_installer"

class HiveDaemonQuiescenceFailurePathsTest < Minitest::Test
  include HiveTestHelper

  ManualClock = Struct.new(:now) do
    def call = now
    def advance(seconds) = self.now += seconds
  end

  Attempt = Struct.new(:attempt_id, :state, :task_id) do
    def [](key) = key.to_s == "task_id" ? task_id : nil
  end

  Outcome = Struct.new(:classification, :attempt, :evidence)

  class Dataset
    def initialize(rows)
      @rows = rows
    end

    def where(*) = self
    def order(*) = self
    def all = @rows
    def any? = @rows.any?
  end

  class Connection
    def initialize(tables)
      @tables = tables
    end

    def [](table) = @tables.fetch(table)
  end

  class ReadDatabase
    attr_reader :path

    def initialize(tables = {}, error: nil)
      @tables = tables
      @error = error
      @path = "/tmp/runtime-control-plane.sqlite3"
    end

    def read
      raise @error if @error

      yield Connection.new(@tables)
    end

    def disconnected? = false
    def open!(**) = self
    def disconnect = true
  end

  def test_finalization_proof_rejects_unsafe_custody_and_validates_nonempty_arrays
    with_tmp_dir do |root|
      lifecycle = Hive::RuntimeControlPlane::Lifecycle.new(
        phase: "paused", generation: 2, revision: 3, mutation_sequence: 4,
        boot_id: "boot", deadline_monotonic: 10, shutdown_grace_sec: 1,
        interrupted_attempt_ids: [ "attempt-1" ], quiesce_started_at: nil,
        paused_at: nil, resumed_at: nil, updated_at: nil
      )
      proof = Hive::Daemon::FinalizationProof.new(state_home: root)
      proof.publish!(
        lifecycle: lifecycle, installation_id: "installation-1",
        checkpoint: { complete: true, busy: 0, log_frames: 0, checkpointed_frames: 0 },
        interrupted_attempt_ids: [ "attempt-1" ],
        inventory: [ { role: "service", descendants: [ { pid: 42 } ] } ],
        published_at: Time.utc(2026, 9, 26)
      )
      assert proof.verify(lifecycle: lifecycle, installation_id: "installation-1").valid?

      path = Hive::Paths.runtime_quiescence_proof_path(root)
      File.chmod(0o644, path)
      assert_equal "proof_custody_invalid", proof.read.reason

      File.delete(path)
      File.symlink(File.join(root, "missing-proof-target"), path)
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { proof.remove! }
      assert_equal :proof_custody_invalid, error.code
    end
  end

  def test_invalid_timeouts_and_migration_errors_remain_typed
    assert_raises(ArgumentError) { Hive::Daemon::Quiescence.new(timeout_sec: 0) }
    assert_raises(ArgumentError) { Hive::Daemon::Resume.new(timeout_sec: Float::INFINITY) }

    migration = Hive::RuntimeControlPlane::MigrationRequired.new("upgrade", code: :upgrade)
    database = Object.new
    database.define_singleton_method(:open!) { |**| raise migration }
    database.define_singleton_method(:disconnect) { true }

    assert_same migration, assert_raises(Hive::RuntimeControlPlane::MigrationRequired) {
      quiescence_shell(database: database).call
    }
    assert_same migration, assert_raises(Hive::RuntimeControlPlane::MigrationRequired) {
      resume_shell(database: database).call
    }
  end

  def test_quiescence_reports_busy_lifecycle_and_final_inventory
    with_runtime do |root, database|
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      closed = lifecycle.begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 1
      )
      database.with_exclusive_writer(role: :controller) do |authority|
        lifecycle.begin_resume!(generation: closed.generation, authority: authority)
      end
      result = coordinator(root, database).call
      assert_equal "lifecycle_busy", result.reason
    end

    with_runtime do |root, database|
      capability = sequence_capability(eligible, eligible, refusal("late_inventory"))
      result = coordinator(root, database, capability: capability).call
      assert_equal "work_remaining", result.reason
      assert_equal "late_inventory", result.remaining.first.fetch("unknown_reason")
    end
  end

  def test_quiescence_bounds_finalization_deadlines_and_writer_contention
    with_runtime do |root, database|
      clock = ManualClock.new(100.0)
      final_capability = Object.new
      eligible_verdict = eligible
      calls = 0
      final_capability.define_singleton_method(:call) do
        calls += 1
        clock.advance(1) if calls == 3
        eligible_verdict
      end
      result = coordinator(
        root, database, timeout_sec: 1, capability: final_capability,
        monotonic: clock.method(:call), sleeper: ->(seconds) { clock.advance(seconds) }
      ).call
      assert_equal "deadline_exhausted", result.reason
    end

    with_runtime do |root, database|
      original = database.method(:with_exclusive_writer)
      calls = 0
      database.define_singleton_method(:with_exclusive_writer) do |**kwargs, &block|
        calls += 1
        if calls == 1
          original.call(**kwargs, &block)
        else
          raise Hive::ConcurrentRunError.new("busy", lock_path: "/writer")
        end
      end
      result = coordinator(root, database).call
      assert_equal "writer_drain_timeout", result.reason
      assert_equal "writer_fence_busy", result.remaining.first.fetch("unknown_reason")
    end
  end

  def test_checkpoint_deadlines_roll_back_the_paused_candidate
    lifecycle = Object.new
    restored = running_lifecycle
    lifecycle.define_singleton_method(:return_to_quiescing!) { |**| restored }
    database = Object.new
    database.define_singleton_method(:checkpoint!) do |timeout_sec:|
      { complete: true, busy: 0, log_frames: 0, checkpointed_frames: 0 }
    end

    clock = ManualClock.new(100.0)
    controller = quiescence_shell(database: database, lifecycle: lifecycle,
                                  monotonic: clock.method(:call))
    set_budget(controller, deadline: 100.0)
    result = controller.send(:checkpoint_candidate, candidate, authority: Object.new)
    assert_equal "deadline_exhausted", result.reason

    readings = [ 99.0, 100.0 ]
    controller = quiescence_shell(
      database: database, lifecycle: lifecycle,
      monotonic: -> { readings.empty? ? 100.0 : readings.shift }
    )
    set_budget(controller, deadline: 100.0)
    result = controller.send(:checkpoint_candidate, candidate, authority: Object.new)
    assert_equal "deadline_exhausted", result.reason
    assert result.checkpoint.fetch(:complete)
  end

  def test_proof_cleanup_failure_does_not_mask_publication_failure
    with_runtime do |root, database|
      removals = 0
      proof = Object.new
      proof.define_singleton_method(:remove!) do
        removals += 1
        raise IOError, "cleanup failed" if removals > 1

        true
      end
      proof.define_singleton_method(:publish!) { |**| raise IOError, "publish failed" }
      result = coordinator(root, database, proof_store: proof).call
      assert_equal "proof_publication_failed", result.reason
      assert_match(/publish failed/, result.details.fetch("error"))
    end
  end

  def test_attempt_and_inventory_helpers_preserve_all_unresolved_evidence
    running = Attempt.new("attempt-running", "running", "task-1")
    launching = Attempt.new("attempt-launching", "launching", "task-2")
    store = Object.new
    store.define_singleton_method(:active_attempts) { [ running, launching ] }
    reconciler = Object.new
    reconciler.define_singleton_method(:finalize_interruption) do |record, **|
      Outcome.new(:interrupted, record, "stopped")
    end
    controller = quiescence_shell(attempt_store: store, reconciler: reconciler)
    controller.define_singleton_method(:durable_interrupted_attempts) { |_| [ "attempt-old" ] }
    set_budget(controller)
    interrupted = controller.send(
      :finalize_stopped_processes_and_attempts, generation: 2, authority: Object.new
    )
    assert_equal %w[attempt-old attempt-running], interrupted

    controller = quiescence_shell
    controller.define_singleton_method(:durable_interrupted_attempts) { |_| [] }
    controller.define_singleton_method(:attempt_store_if_needed) { store }
    set_budget(controller)
    with_replaced_singleton_method(Hive::Attempts::Reconciler, :new, ->(**) { reconciler }) do
      assert_equal [ "attempt-running" ], controller.send(
        :finalize_stopped_processes_and_attempts, generation: 2, authority: Object.new
      )
    end

    controller = quiescence_shell(capability: sequence_capability(refusal("late_attempt")))
    controller.define_singleton_method(:live_process_evidence) { [] }
    controller.define_singleton_method(:live_attempt_rows) do
      [ { attempt_id: "attempt-2", task_id: "task-2", state: "running" } ]
    end
    controller.define_singleton_method(:unresolved_reservations) { [] }
    remaining = controller.send(:final_remaining)
    assert_equal %w[attempt_not_reconciled late_attempt],
                 remaining.map { |entry| entry.fetch("unknown_reason") }
  end

  def test_process_signal_and_descendant_failures_remain_observable
    identity = Object.new
    identity.define_singleton_method(:status) { |_| :matching }
    controller = quiescence_shell(
      process_identity: identity,
      signaler: ->(*) { raise Errno::ESRCH }
    )
    live = [ {
      row: { pid: 42, start_fingerprint: "start-42" }, descendants: []
    } ]
    assert_equal [ 42 ], controller.send(:signal_processes, "TERM", live).map { |row| row.fetch("pid") }

    custody = Object.new
    custody.define_singleton_method(:members) { |_, timeout_sec:| raise IOError, "offline" }
    controller = quiescence_shell(process_identity: identity, custody: custody)
    row = {
      process_id: "process-1", pid: 42, custody_mode: "delegated_cgroup_v2",
      custody_path: "/hive/test"
    }
    cache = controller.send(:descendant_cache, row)
    cache[[ 43, "start-43" ]] = { "pid" => 43, "start_fingerprint" => "start-43" }
    descendants, error = controller.send(:custody_member_evidence, row)
    assert_equal [ 43 ], descendants.map { |entry| entry.fetch("pid") }
    assert_equal "custody_inventory_unavailable:IOError", error

    controller.instance_variable_set(:@proof_inventory, [ { "process_id" => "process-1" } ])
    proof_inventory = controller.send(:proof_inventory)
    assert_equal %w[process-1 process-1], proof_inventory.map { |entry| entry.fetch("process_id") }
    assert_equal "descendant", proof_inventory.last.fetch("role")
  end

  def test_reservation_attempt_and_receipt_helpers_fail_closed
    reservation_rows = [ {
      reservation_id: "reservation-1", attempt_id: "attempt-1", task_id: "task-1",
      origin: "attempt", role: "worker", owner_pid: 42, state: "reserved"
    } ]
    database = ReadDatabase.new({ launch_reservations: Dataset.new(reservation_rows) })
    controller = quiescence_shell(database: database)
    assert_equal "reservation-1",
                 controller.send(:unresolved_reservations).first.fetch("reservation_id")

    error_database = ReadDatabase.new(
      {}, error: Hive::RuntimeControlPlane::Unavailable.new("offline", code: :offline)
    )
    assert_empty quiescence_shell(database: error_database).send(:unresolved_reservations)

    attempts = Dataset.new([ { attempt_id: "attempt-1", state: "running" } ])
    database = ReadDatabase.new({ attempts: attempts })
    repository = Object.new
    controller = quiescence_shell(database: database)
    with_replaced_singleton_method(Hive::Attempts::Repository, :new, ->(**) { repository }) do
      assert_same repository, controller.send(:attempt_store_if_needed)
    end

    receipts = Dataset.new([
      { attempt_id: "matched", terminal_receipt_json: '{"pause_generation":2}' },
      { attempt_id: "other", terminal_receipt_json: '{"pause_generation":3}' },
      { attempt_id: "invalid", terminal_receipt_json: "{" }
    ])
    database = ReadDatabase.new({ attempts: receipts })
    assert_equal [ "matched" ],
                 quiescence_shell(database: database).send(:durable_interrupted_attempts, 2)
  end

  def test_safe_lifecycle_fallbacks_handle_unreadable_state
    lifecycle = Object.new
    lifecycle.define_singleton_method(:current) { raise IOError, "offline" }
    assert_nil quiescence_shell(lifecycle: lifecycle).send(:safe_lifecycle)
    assert_nil resume_shell(lifecycle: lifecycle).send(:safe_lifecycle)
  end

  def test_resume_reconciliation_covers_unverifiable_and_nonterminal_attempts
    with_runtime do |root, database|
      insert_active_process(database)
      close_admission(database)
      identity = Object.new
      identity.define_singleton_method(:status) { |_| :unverifiable }
      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, process_identity: identity, timeout_sec: 1
      ).call
      assert_equal "process_identity_unverifiable",
                   result.remaining.first.fetch("unknown_reason")
    end

    with_runtime do |root, database|
      close_admission(database)
      active = Attempt.new("active-1", "running", "task-1")
      store = Object.new
      store.define_singleton_method(:active_attempts) { [ active ] }
      reconciler = Object.new
      reconciler.define_singleton_method(:finalize_interruption) do |record, **|
        Outcome.new(:active, record, "still_running")
      end
      reconciler.define_singleton_method(:reconcile) do |**|
        Struct.new(:attempts).new([
          Outcome.new(:active, Attempt.new("active-2", "launching", "task-2"), "launching"),
          Outcome.new(:lost, Attempt.new("lost-1", "terminal", "task-3"), "lost")
        ])
      end
      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        attempt_store: store, reconciler: reconciler
      ).call
      assert_equal "reconciliation_incomplete", result.reason
      assert_equal %w[active-1 active-2], result.remaining.map { |entry| entry.fetch("attempt_id") }
      assert_equal [ "lost-1" ], result.reconciled_attempt_ids
    end
  end

  def test_resume_rejects_an_unknown_lifecycle_phase
    lifecycle = Object.new
    lifecycle.define_singleton_method(:current) do
      Hive::RuntimeControlPlane::Lifecycle.new(
        phase: "unknown", generation: 2, revision: 3, mutation_sequence: 4,
        boot_id: "boot", deadline_monotonic: nil, shutdown_grace_sec: nil,
        interrupted_attempt_ids: [], quiesce_started_at: nil, paused_at: nil,
        resumed_at: nil, updated_at: nil
      )
    end
    result = resume_shell(lifecycle: lifecycle).call
    assert_equal "lifecycle_busy", result.reason
    refute result.resumed
  end

  def test_resume_deadline_and_service_failures_are_reported_after_reopening
    with_runtime do |root, database|
      close_admission(database)
      clock = ManualClock.new(100.0)
      store = Object.new
      store.define_singleton_method(:active_attempts) { [] }
      reconciler = Object.new
      reconciler.define_singleton_method(:reconcile) do |**|
        clock.advance(1)
        Struct.new(:attempts).new([])
      end
      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        attempt_store: store, reconciler: reconciler, monotonic: clock.method(:call)
      ).call
      assert_equal "deadline_exhausted", result.reason
      refute result.admission_reopened
    end

    with_runtime do |root, database|
      insert_quiesced_service(database, "hive-web")
      close_admission(database)
      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        service_restorer: ->(**) { raise IOError, "start failed" }
      ).call
      assert_equal "start_failed", result.services.first.fetch("reason")
      assert_match(/start failed/, result.services.first.fetch("error"))
    end

    with_runtime do |root, database|
      insert_quiesced_service(database, "hive-web")
      controller = Hive::Daemon::Resume.new(state_home: root, database: database, timeout_sec: 1)
      controller.instance_variable_set(:@deadline, 100.0)
      controller.instance_variable_set(:@monotonic, -> { 100.0 })
      result = controller.send(:restore_services, running_lifecycle)
      assert_equal "deadline_exhausted", result.services.first.fetch("reason")
    end
  end

  def test_resume_helpers_project_reservations_and_construct_the_default_store
    reservations = Dataset.new([ { reservation_id: "reservation-1", state: "reserved" } ])
    attempts = Dataset.new([ { attempt_id: "attempt-1", state: "running" } ])
    database = ReadDatabase.new({ launch_reservations: reservations, attempts: attempts })
    controller = resume_shell(database: database)
    assert_equal "launch_reservation_unresolved",
                 controller.send(:active_reservations).first.fetch("unknown_reason")

    repository = Object.new
    with_replaced_singleton_method(Hive::Attempts::Repository, :new, ->(**) { repository }) do
      assert_same repository, controller.send(:attempt_store_if_needed)
    end
  end

  def test_default_service_restoration_supports_every_managed_identity
    controller = resume_shell
    installers = {
      "hive-daemon" => Hive::Commands::Daemon::ServiceInstaller,
      "hive-web" => Hive::Commands::Web::ServiceInstaller,
      "hive-bot" => Hive::Commands::Bot::ServiceInstaller,
      "hive-babysitter" => Hive::Commands::Babysit::ServiceInstaller
    }
    fake = Object.new
    fake.define_singleton_method(:start!) { true }

    replacements = installers.values.map { |klass| [ klass, klass.method(:new) ] }
    installers.each_value { |klass| klass.define_singleton_method(:new) { |**| fake } }
    installers.each_key do |identity|
      result = controller.send(:restore_managed_service, service_identity: identity, timeout_sec: 1)
      assert_equal true, result.fetch("ok")
    end
    unsupported = controller.send(
      :restore_managed_service, service_identity: "other", timeout_sec: 1
    )
    assert_equal "unsupported_service_identity", unsupported.fetch("reason")
  ensure
    replacements&.each { |klass, original| klass.define_singleton_method(:new, original) }
  end

  private

  def quiescence_shell(database: ReadDatabase.new({ attempts: Dataset.new([]) }), lifecycle: nil,
                       capability: nil, process_identity: nil, custody: nil,
                       attempt_store: nil, reconciler: nil, monotonic: -> { 0.0 },
                       signaler: ->(*) { true })
    lifecycle ||= Object.new.tap do |value|
      value.define_singleton_method(:current) { running_lifecycle }
    end
    capability ||= sequence_capability(eligible)
    process_identity ||= Object.new.tap do |value|
      value.define_singleton_method(:status) { |_| :missing }
    end
    custody ||= Object.new
    registry = Object.new
    registry.define_singleton_method(:active_rows) { [] }
    proof = Object.new
    proof.define_singleton_method(:remove!) { true }
    proof.define_singleton_method(:verify) { |**| Hive::Daemon::ProofVerdict.new(valid: false, reason: "missing", payload: nil) }
    Hive::Daemon::Quiescence.new(
      state_home: "/tmp/hive-quiescence-coverage", database: database,
      lifecycle: lifecycle, registry: registry, capability: capability,
      process_identity: process_identity, custody: custody,
      attempt_store: attempt_store, reconciler: reconciler, proof_store: proof,
      monotonic: monotonic, boot_id_reader: -> { "boot-test" }, signaler: signaler
    )
  end

  def resume_shell(database: ReadDatabase.new({ attempts: Dataset.new([]) }), lifecycle: nil)
    lifecycle ||= Object.new.tap do |value|
      value.define_singleton_method(:current) { running_lifecycle }
    end
    registry = Object.new
    registry.define_singleton_method(:active_rows) { [] }
    proof = Object.new
    proof.define_singleton_method(:remove!) { true }
    Hive::Daemon::Resume.new(
      state_home: "/tmp/hive-quiescence-coverage", database: database,
      lifecycle: lifecycle, registry: registry, proof_store: proof
    )
  end

  def set_budget(controller, deadline: 200.0)
    controller.instance_variable_set(
      :@budget,
      Hive::Daemon::Quiescence::Budget.new(
        started_at: 0.0, drain_cutoff: deadline, escalation_cutoff: deadline,
        deadline: deadline
      )
    )
  end

  def candidate
    Struct.new(:generation, :revision).new(2, 3)
  end

  def eligible
    Hive::RuntimeControlPlane::CapabilityVerdict.new(
      eligible: true, reason: nil, ownership_mode: "registered_only",
      disqualifying_inventory: []
    )
  end

  def refusal(reason)
    Hive::RuntimeControlPlane::CapabilityVerdict.new(
      eligible: false, reason: reason, ownership_mode: "unverified",
      disqualifying_inventory: [ { "attempt_id" => "attempt-1" } ]
    )
  end

  def sequence_capability(*verdicts)
    Object.new.tap do |value|
      value.define_singleton_method(:call) do
        verdicts.length > 1 ? verdicts.shift : verdicts.fetch(0)
      end
    end
  end

  def coordinator(root, database, timeout_sec: 1, capability: nil, **options)
    Hive::Daemon::Quiescence.new(
      state_home: root, database: database, timeout_sec: timeout_sec,
      capability: capability || sequence_capability(eligible, eligible, eligible),
      boot_id_reader: -> { "boot-test" }, **options
    )
  end

  def close_admission(database)
    Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
      deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 1
    )
  end

  def insert_active_process(database)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      db[:owned_processes].insert(
        process_id: "active-process", installation_id: db[:installations].get(:installation_id),
        origin: "safe_fixture", role: "service", pid: 123_456,
        start_fingerprint: "fixture-start", state: "running", proven_child_safe: 1,
        custody_mode: "unverified", created_at: now, updated_at: now
      )
    end
  end

  def insert_quiesced_service(database, identity)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      db[:owned_processes].insert(
        process_id: "service-process", installation_id: db[:installations].get(:installation_id),
        service_identity: identity, origin: "safe_fixture", role: "service",
        state: "stopped", proven_child_safe: 1, custody_mode: "unverified",
        unknown_reason: "quiesced", created_at: now, updated_at: now, stopped_at: now
      )
    end
  end

  def running_lifecycle
    Hive::RuntimeControlPlane::Lifecycle.new(
      phase: "running", generation: 2, revision: 3, mutation_sequence: 4,
      boot_id: "boot", deadline_monotonic: nil, shutdown_grace_sec: nil,
      interrupted_attempt_ids: [], quiesce_started_at: nil, paused_at: nil,
      resumed_at: nil, updated_at: nil
    )
  end

  def with_runtime
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield root, database
    ensure
      database&.disconnect
    end
  end
end
