require "test_helper"
require "hive/attempts/finalization_maintenance"
require "hive/attempts/reconciler"
require "hive/task_action"

class AttemptsFinalizationMaintenanceTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  CAPABILITY = "c" * 64

  def test_partial_acknowledgements_resume_and_publish_terminal_payloads_once
    with_repository do |store|
      terminal = terminal_attempt(store)
      subject = maintenance(store)

      assert subject.prepare(terminal)
      subject.acknowledge(terminal, :journal)
      refute subject.promote(terminal)
      assert store.fetch_hot(terminal.attempt_id)

      subject.acknowledge(terminal, :dispatch)
      subject.acknowledge(terminal, :accounting)
      assert subject.promote(terminal)
      assert_nil store.fetch_hot(terminal.attempt_id)
      assert_equal terminal.to_h, store.fetch(terminal.attempt_id).to_h
      assert_equal :available, store.log_archive.resolve(terminal.attempt_id).availability
      count = store.database.read do |db|
        db[:payload_references].where(attempt_id: terminal.attempt_id, kind: "attempt_log").count
      end
      assert_equal 1, count
    end
  end

  def test_active_log_writer_keeps_completed_publication_pending
    with_repository do |store|
      running = running_attempt(store)
      writer = store.log_archive.open_writer(running.attempt_id, clock: -> { NOW })
      writer.append(:stdout, "still open\n")
      reference = Hive::OutputReference.build(writer.path, root: store.root)
      terminal = terminalize(store, running, log_reference: reference)
      subject = maintenance(store)
      prepare_all(subject, terminal)

      refute subject.promote(terminal)
      assert store.fetch(terminal.attempt_id)
      restarted = Hive::Attempts::Repository.new(root: store.root, migrate: true)
      assert_equal terminal.attempt_id,
                   restarted.active_attempts.find { |attempt| attempt.attempt_id == terminal.attempt_id }&.attempt_id
      writer.close
      assert subject.promote(terminal)
      assert_nil store.fetch_hot(terminal.attempt_id)
    ensure
      writer&.close unless writer&.closed?
    end
  end

  def test_retention_sweep_is_sql_bounded_and_preserves_attempt_proof
    with_repository do |store|
      terminal = terminal_attempt(store)
      subject = maintenance(store)
      prepare_all(subject, terminal)
      assert subject.promote(terminal)

      early = subject.sweep_logs(now: NOW + 86_400)
      assert_equal 0, early.fetch(:deleted)
      assert_operator early.fetch(:cold_examined), :<=,
                      Hive::Attempts::FinalizationMaintenance::COLD_SWEEP_LIMIT

      restarted = maintenance(store)
      expired = restarted.sweep_logs(now: NOW + (3 * 86_400) + 4)
      assert_equal 1, expired.fetch(:deleted)
      assert_equal :expired, store.log_archive.resolve(terminal.attempt_id).availability
      assert_equal terminal.to_h, store.fetch(terminal.attempt_id).to_h
    end
  end

  def test_archived_task_can_release_terminal_payloads_before_age_retention
    with_repository do |store|
      terminal = terminal_attempt(store)
      subject = maintenance(store, task_archived: ->(record) { record.attempt_id == terminal.attempt_id })
      prepare_all(subject, terminal)
      assert subject.promote(terminal)

      assert_equal 1, subject.sweep_logs(now: NOW + 60).fetch(:deleted)
      assert_equal :expired, store.log_archive.resolve(terminal.attempt_id).availability
    end
  end

  def test_canonical_task_action_not_done_folder_controls_early_expiry
    with_repository do |store|
      terminal = terminal_attempt(store)
      state_root = File.join(store.root, "project-state")
      folder = File.join(state_root, "stages", "9-done", terminal["task_slug"])
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- COMPLETE -->\n")
      task = Struct.new(:id, :state_file, :project_root, :folder)
        .new(terminal["task_id"], state_file, "/demo", folder)
      marker = Struct.new(:name).new(:complete)
      action = Struct.new(:key).new(Hive::Schemas::TaskActionKind::READY_TO_ARCHIVE)
      projection = Object.new
      bounded = Struct.new(:projection) { def current? = true }.new(projection)
      history_reader = Object.new
      history_reader.define_singleton_method(:read_routine) { |**| bounded }
      observed_projections = []
      subject = Hive::Attempts::FinalizationMaintenance.new(store: store)
      assert_equal [ folder ], Dir.glob(
        File.join(state_root, "stages", "*", terminal["task_slug"])
      )
      assert_equal terminal["task_id"].to_s, task.id.to_s

      with_replaced_singleton_method(
        Hive::Config, :find_project,
        ->(_name) { { "hive_state_path" => state_root } }
      ) do
        with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { task }) do
          with_replaced_singleton_method(Hive::Markers, :current, ->(_path) { marker }) do
            with_replaced_singleton_method(Hive::Config, :load, ->(_root) { {} }) do
              with_replaced_singleton_method(
                Hive::TaskProjection::Reader, :new, ->(**) { history_reader }
              ) do
                action_for = lambda do |*_args, **kwargs|
                  observed_projections << kwargs.fetch(:projection)
                  action
                end
                with_replaced_singleton_method(Hive::TaskAction, :for, action_for) do
                  refute subject.send(:task_archived?, terminal)
                  assert_equal [ projection ], observed_projections
                  action.key = Hive::Schemas::TaskActionKind::ARCHIVED
                  assert subject.send(:task_archived?, terminal)
                end
              end
            end
          end
        end
      end
      assert_equal [ projection, projection ], observed_projections
    end
  end

  def test_tempfail_refund_is_typed_and_idempotent
    with_repository do |store|
      terminal = terminal_attempt(store, exit_status: Hive::ExitCodes::TEMPFAIL)
      subject = maintenance(store)

      2.times { assert subject.prepare(terminal) }
      assert subject.finalize(terminal, now: NOW + 4)
      accounting = store.database.read do |db|
        db[:attempts].where(attempt_id: terminal.attempt_id).first
      end
      assert_equal 1, accounting.fetch(:refunded)
    end
  end

  def test_downstream_delivery_starts_only_after_task_journal_acknowledgement
    with_repository do |store|
      terminal = terminal_attempt(store)
      order = []
      results = [ :unavailable, :delivered ]
      observer = Object.new
      observer.define_singleton_method(:observe) do |*|
        order << :journal
        results.shift
      end
      subject = Hive::Attempts::FinalizationMaintenance.new(
        store: store, condition_observer: observer,
        delivery_pending: lambda do |_record|
          order << :delivery
          false
        end,
        task_archived: ->(_record) { false }
      )

      refute subject.finalize(terminal, now: NOW + 4)
      assert_equal [ :journal ], order
      assert_equal({
        "accounting" => false, "journal" => false, "dispatch" => false
      }, store.publication(terminal.attempt_id).fetch("consumers"))

      assert subject.finalize(terminal, now: NOW + 5)
      assert_equal [ :journal, :journal, :delivery ], order
      assert_nil store.fetch_hot(terminal.attempt_id)
    end
  end

  def test_daemon_reconciliation_makes_terminal_publication_promotable_without_another_dispatch
    with_repository do |store|
      terminal = terminal_attempt(store)
      observer = Struct.new(:result) do
        def observe(*) = result
      end.new(:delivered)
      finalization = Hive::Attempts::FinalizationMaintenance.new(
        store: store, condition_observer: observer,
        delivery_pending: ->(_record) { false },
        task_archived: ->(_record) { false }
      )
      reconciler = Hive::Attempts::Reconciler.new(
        store: store, condition_observer: observer,
        finalization_maintenance: finalization
      )

      reconciler.reconcile(now: NOW + 4)
      pending = store.publication(terminal.attempt_id)
      assert_equal true, pending.dig("consumers", "journal")
      assert_equal true, pending.dig("consumers", "accounting")
      assert_equal false, pending.dig("consumers", "dispatch")

      assert reconciler.acknowledge_finalization(terminal, :dispatch)
      assert reconciler.promote_finalization(terminal)
      assert_nil store.fetch_hot(terminal.attempt_id)
    end
  end

  def test_maintenance_timing_and_status_are_process_local
    with_repository do |store|
      subject = maintenance(store)

      first = subject.sweep_if_due(now: NOW + 60)
      assert first.fetch(:ran)
      refute subject.sweep_if_due(now: NOW + 61).fetch(:ran)
      restarted = maintenance(store)
      assert restarted.sweep_if_due(now: NOW + 61).fetch(:ran)
      snapshot = subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "healthy", snapshot.fetch("status")
      assert_equal({
        "promoted" => 0, "deleted" => 0, "cold_examined" => 0,
        "errors" => 0
      }, snapshot.dig("maintenance", "last_result"))
    end
  end

  def test_cold_sweep_cursor_advances_only_within_the_current_process
    with_repository do |store|
      seen = []
      page = Data.define(:attempt_ids, :cursor)
      archive = Object.new
      archive.define_singleton_method(:cold_attempt_ids_page) do |cursor:, limit:|
        seen << [ cursor, limit ]
        after = seen.one? ? "attempt-1" : "attempt-2"
        page.new(
          attempt_ids: [].freeze, cursor: { "after" => after }.freeze
        )
      end
      store.define_singleton_method(:log_archive) { archive }

      subject = maintenance(store)
      assert subject.sweep_if_due(now: NOW).fetch(:ran)
      assert subject.sweep_if_due(
        now: NOW + Hive::Attempts::FinalizationMaintenance::MAINTENANCE_INTERVAL_SEC
      ).fetch(:ran)
      assert maintenance(store).sweep_if_due(now: NOW).fetch(:ran)
      assert_equal [ nil, "attempt-1", nil ], seen.map { |cursor, _limit| cursor.fetch("after") }
    end
  end

  def test_cold_sweep_stops_at_its_time_budget_and_resumes_after_the_last_examined_row
    record = Struct.new(:attempt_id) do
      def final? = true
      def [](key) = key == "ended_at" ? "2026-08-01T00:00:00Z" : nil
    end
    pages = []
    page = Data.define(:attempt_ids, :cursor)
    archive = Object.new
    archive.define_singleton_method(:cold_attempt_ids_page) do |cursor:, **|
      pages << cursor.fetch("after")
      ids = cursor.fetch("after") == "attempt-1" ? %w[attempt-2 attempt-3] : %w[attempt-1 attempt-2 attempt-3]
      page.new(attempt_ids: ids, cursor: { "after" => ids.last })
    end
    archive.define_singleton_method(:expire) { |*, **| :expired }
    store = Object.new
    store.define_singleton_method(:log_archive) { archive }
    store.define_singleton_method(:publication) { |_| nil }
    store.define_singleton_method(:fetch) { |id| record.new(id) }
    clock_values = [ 0.0, 1.0, 6.0, 10.0, 11.0, 12.0 ]
    subject = Hive::Attempts::FinalizationMaintenance.new(
      store: store, task_archived: ->(_) { false },
      monotonic_clock: -> { clock_values.shift }, maintenance_time_budget_sec: 5
    )

    first = subject.sweep_logs(now: NOW)
    second = subject.sweep_logs(now: NOW)

    assert_equal 1, first.fetch(:cold_examined)
    assert_equal 2, second.fetch(:cold_examined)
    assert_equal [ nil, "attempt-1" ], pages
  end

  def test_maintenance_error_is_visible_only_in_the_current_process
    with_repository do |store|
      archive = Object.new
      archive.define_singleton_method(:cold_attempt_ids_page) { |**| raise ArgumentError, "bad page" }
      store.define_singleton_method(:log_archive) { archive }

      subject = maintenance(store)
      assert_raises(ArgumentError) { subject.sweep_if_due(now: NOW) }
      snapshot = subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "degraded", snapshot.fetch("status")
      assert_equal "maintenance_failed", snapshot.fetch("degraded_reason")
      assert_equal "ArgumentError", snapshot.dig("last_error", "class")
      assert_equal NOW.iso8601(6), snapshot.dig("last_error", "observed_at")
      assert_equal "unknown",
                   maintenance(store).storage_snapshot(
                     hot_count: 0, invalid_hot_count: 0
                   ).fetch("status")
    end
  end

  def test_a_failing_oldest_cleanup_does_not_block_a_later_candidate
    record = Struct.new(:attempt_id) do
      def final? = true
      def [](key) = key == "ended_at" ? "2026-08-01T00:00:00Z" : nil
    end
    page = Data.define(:attempt_ids, :cursor).new(
      attempt_ids: %w[bad good], cursor: { "after" => "good" }
    )
    archive = Object.new
    archive.define_singleton_method(:cold_attempt_ids_page) { |**| page }
    archive.define_singleton_method(:expire) { |id, **| id == "good" ? :expired : :missing }
    store = Object.new
    store.define_singleton_method(:log_archive) { archive }
    store.define_singleton_method(:publication) { |_| nil }
    store.define_singleton_method(:database) do
      Struct.new(:diagnostics).new(Struct.new(:ok?, :error).new(true, nil))
    end
    store.define_singleton_method(:fetch) do |id|
      raise Hive::Attempts::RepositoryError, "permanently bad" if id == "bad"

      record.new(id)
    end
    subject = Hive::Attempts::FinalizationMaintenance.new(
      store: store, task_archived: ->(_) { false }
    )

    result = subject.sweep_if_due(now: NOW)
    assert_equal 1, result.fetch(:deleted)
    assert_equal 1, result.fetch(:errors)
    snapshot = subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
    assert_equal "maintenance_failed", snapshot.fetch("degraded_reason")
    assert_equal "bad", snapshot.dig("last_error", "attempt_id")
  end

  def test_runtime_wires_dispatch_delivery_without_provider_health
    with_repository do |store|
      subject = Hive::Attempts::FinalizationMaintenance.runtime(store: store)
      delivery = subject.instance_variable_get(:@delivery_pending)

      refute subject.instance_variable_defined?(:@provider_health_observer_factory)
      refute delivery.call(Struct.new(:attempt_id).new("missing"))
    end
  end

  def test_delivery_fails_closed_on_collaborator_errors
    record = Struct.new(:attempt_id).new("attempt")
    subject = Hive::Attempts::FinalizationMaintenance.new(
      store: Object.new,
      delivery_pending: ->(_) { raise Hive::Error, "bad" }
    )

    assert subject.send(:delivery_pending?, record)
  end

  def test_promote_rejects_mismatched_proof_and_post_archive_hot_mutation
    with_repository do |store|
      terminal = terminal_attempt(store)
      subject = maintenance(store)
      prepare_all(subject, terminal)
      forged = terminal.with("diagnostics" => terminal["diagnostics"].merge("forged" => true))
      assert_raises(Hive::Attempts::RepositoryError) { subject.promote(forged) }

      archive = Object.new
      archive.define_singleton_method(:archive) do |_attempt_id|
        changed = terminal.with("diagnostics" => terminal["diagnostics"].merge("changed" => true))
        store.database.transaction do |db|
          db[:attempts].where(attempt_id: terminal.attempt_id).update(
            details_json: Hive::RuntimeControlPlane::Codec.dump_json(changed.to_h.slice(*Hive::Attempts::Record::DETAIL_KEYS))
          )
        end
        :archived
      end
      store.define_singleton_method(:log_archive) { archive }
      assert_raises(Hive::Attempts::RepositoryError) { subject.promote(terminal) }
    end
  end

  def test_storage_and_retention_helpers_fail_closed
    with_repository do |store|
      subject = maintenance(store)
      store.database.define_singleton_method(:diagnostics) do
        raise Hive::RuntimeControlPlane::IntegrityError.new("bad", code: :database_corrupt)
      end
      snapshot = subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "degraded", snapshot.fetch("status")
      assert_equal "database_unhealthy", snapshot.fetch("degraded_reason")
    end

    broken_store = Object.new
    broken_store.define_singleton_method(:publication) do |_|
      raise Hive::Attempts::RepositoryError, "bad"
    end
    subject = Hive::Attempts::FinalizationMaintenance.new(store: broken_store)
    record = Struct.new(:attempt_id) do
      def [](key) = key == "ended_at" ? "not-a-time" : nil
    end.new("attempt")
    assert subject.send(:recovery_pinned?, record)
    refute subject.send(:retention_expired?, record, now: NOW)

    pending_store = Object.new
    pending_store.define_singleton_method(:publication) { |_| Object.new }
    pending_store.define_singleton_method(:publication_complete?) { |_| false }
    pending = Hive::Attempts::FinalizationMaintenance.new(store: pending_store)
    assert pending.send(:recovery_pinned?, record)
  end

  def test_archived_task_lookup_and_loss_resolution_checks_are_bounded
    record = Struct.new(:attempt_id, :task_generation, :subject) do
      def [](key)
        { "project" => "demo", "task_slug" => "task", "task_id" => "42" }[key]
      end
    end.new("lost", "generation", { "kind" => "task_stage" })
    store = Object.new
    subject = Hive::Attempts::FinalizationMaintenance.new(store: store)
    transition = Object.new
    transition.define_singleton_method(:fetch) do |_|
      { "phase" => "complete", "cleanup" => "absent",
        "request_id" => "recovery-request" }
    end

    with_replaced_singleton_method(Hive::Attempts::LostOutcomeTransition, :new, ->(**) { transition }) do
      assert subject.send(:resolved_loss?, record)
    end
    with_replaced_singleton_method(
      Hive::Attempts::LostOutcomeTransition, :new,
      ->(**) { raise Hive::Attempts::RepositoryError, "bad" }
    ) do
      refute subject.send(:resolved_loss?, record)
    end

    with_replaced_singleton_method(Hive::Config, :find_project, lambda { |_|
      raise Hive::Error, "bad"
    }) do
      refute subject.send(:task_archived?, record)
    end

    with_tmp_dir do |state_root|
      FileUtils.mkdir_p(File.join(state_root, "stages", "4-execute", "task"))
      with_replaced_singleton_method(
        Hive::Config, :find_project, ->(_) { { "hive_state_path" => state_root } }
      ) do
        with_replaced_singleton_method(Hive::Task, :new, ->(_) { raise Hive::Error, "bad" }) do
          refute subject.send(:task_archived?, record)
        end
      end
    end

    refunded = []
    store.define_singleton_method(:refund_unstarted) { |value| refunded << value }
    lost = Struct.new(:state) do
      def [](key) = key == "started_at" ? nil : nil
    end.new("lost")
    subject.send(:publish_indexes, lost)
    assert_equal [ lost ], refunded
  end

  def test_maintenance_error_recording_survives_a_broken_logger
    with_repository do |store|
      logger = Object.new
      logger.define_singleton_method(:event) { |*| raise IOError, "logger failed" }
      subject = maintenance(store, logger: logger)

      assert_nil subject.send(
        :record_maintenance_error, IOError.new("sweep failed"),
        now: NOW, attempt_id: "attempt-1"
      )
      assert_equal "IOError",
                   subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
                     .fetch("last_error").fetch("class")
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def maintenance(store, **options)
    observer = Struct.new(:result) do
      def observe(*) = result
    end.new(:delivered)
    Hive::Attempts::FinalizationMaintenance.new(
      store: store,
      condition_observer: observer,
      delivery_pending: ->(_record) { false },
      task_archived: ->(_record) { false },
      **options
    )
  end

  def prepare_all(subject, record)
    assert subject.prepare(record)
    assert subject.acknowledge(record, :journal)
    assert subject.acknowledge(record, :accounting)
    assert subject.acknowledge(record, :dispatch)
  end

  def terminal_attempt(store, exit_status: 0)
    running = running_attempt(store)
    writer = store.log_archive.open_writer(running.attempt_id, clock: -> { NOW })
    writer.append(:stdout, "done\n")
    writer.close
    reference = Hive::OutputReference.build(writer.path, root: store.root)
    terminalize(store, running, log_reference: reference, exit_status: exit_status)
  ensure
    writer&.close unless writer&.closed?
  end

  def terminalize(store, running, log_reference:, exit_status: 0)
    store.terminalize(
      running, outcome: exit_status.zero? ? "succeeded" : "failed",
      exit_status: exit_status,
      final_checkpoint: { "revision" => "a" * 40 }, output_references: [],
      log_reference: log_reference, now: NOW + 3
    )
  end

  def running_attempt(store)
    launching = store.create_launching(
      attempt_id: "attempt-1", request_id: "request-1",
      task_id: "42", project: "demo", task_slug: "task",
      intended_stage: "4-execute", task_generation: "generation-1",
      ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
  end
end
