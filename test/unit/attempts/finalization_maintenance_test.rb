require "test_helper"
require "open3"
require "rbconfig"
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

      subject.acknowledge(terminal, :request_delivery)
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
      assert store.fetch_hot(terminal.attempt_id)
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

      expired = subject.sweep_logs(now: NOW + (3 * 86_400) + 4)
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
      projection_store = Object.new
      projection_store.define_singleton_method(:read_routine) { |**| bounded }
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
                Hive::TaskProjection::Store, :pristine_task?, ->(*) { false }
              ) do
                with_replaced_singleton_method(
                  Hive::TaskProjection::Store, :new, ->(**) { projection_store }
                ) do
                  action_for = lambda do |*_args, **kwargs|
                    observed_projections << kwargs.fetch(:projection)
                    action
                  end
                  with_replaced_singleton_method(Hive::TaskAction, :for, action_for) do
                    refute subject.send(:task_archived?, terminal, attempt_store: store)
                    assert_equal [ projection ], observed_projections
                    action.key = Hive::Schemas::TaskActionKind::ARCHIVED
                    assert subject.send(:task_archived?, terminal, attempt_store: store)
                  end
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
        db[:attempt_accounting].where(attempt_id: terminal.attempt_id).first
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
        "accounting" => false, "journal" => false, "request_delivery" => false
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
      assert_equal false, pending.dig("consumers", "request_delivery")

      assert reconciler.acknowledge_finalization(terminal, :request_delivery)
      assert reconciler.promote_finalization(terminal)
      assert_nil store.fetch_hot(terminal.attempt_id)
    end
  end

  def test_due_maintenance_records_success_and_respects_its_interval
    with_repository do |store|
      terminal = terminal_attempt(store)
      subject = maintenance(store)
      prepare_all(subject, terminal)

      first = subject.run_if_due(now: NOW + 60)
      assert first.fetch(:ran)
      refute maintenance(store).run_if_due(now: NOW + 61).fetch(:ran)
      snapshot = subject.storage_snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "healthy", snapshot.fetch("status")
      assert_equal({
        "promoted" => 1, "deleted" => 0, "cold_examined" => 0
      }, snapshot.dig("maintenance", "last_result"))
    end
  end

  def test_cold_sweep_cursor_resumes_in_a_new_maintenance_instance
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

      assert maintenance(store).sweep_if_due(now: NOW).fetch(:ran)
      assert maintenance(store).sweep_if_due(
        now: NOW + Hive::Attempts::FinalizationMaintenance::MAINTENANCE_INTERVAL_SEC
      ).fetch(:ran)
      assert_equal [ nil, "attempt-1" ], seen.map { |cursor, _limit| cursor.fetch("after") }
    end
  end

  def test_maintenance_error_is_visible_to_a_new_instance
    with_repository do |store|
      archive = Object.new
      archive.define_singleton_method(:cold_attempt_ids_page) { |**| raise ArgumentError, "bad page" }
      store.define_singleton_method(:log_archive) { archive }

      assert_raises(ArgumentError) { maintenance(store).sweep_if_due(now: NOW) }
      snapshot = maintenance(store).storage_snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "degraded", snapshot.fetch("status")
      assert_equal "maintenance_failed", snapshot.fetch("degraded_reason")
      assert_equal "ArgumentError", snapshot.dig("last_error", "class")
      assert_equal NOW.iso8601(6), snapshot.dig("last_error", "observed_at")
    end
  end

  def test_due_claim_serializes_across_processes
    with_repository do |store|
      store.database.disconnect
      script = <<~'RUBY'
        require "time"
        require "hive/attempts/finalization_maintenance"
        database = Hive::RuntimeControlPlane::Database.new(path: ARGV.fetch(0)).open!
        store = Hive::Attempts::Repository.new(database: database, root: ARGV.fetch(1))
        STDIN.read(1)
        result = Hive::Attempts::FinalizationMaintenance.new(store: store)
          .sweep_if_due(now: Time.iso8601(ARGV.fetch(2)))
        puts(result.fetch(:ran) ? "1" : "0")
      RUBY
      processes = 2.times.map do
        Open3.popen3(
          RbConfig.ruby, "-Ilib", "-rbundler/setup", "-e", script,
          store.database.path, store.root, NOW.iso8601(6)
        )
      end
      processes.each { |stdin, *_rest| stdin.write("x"); stdin.close }
      outcomes = processes.map { |_stdin, stdout, _stderr, _wait| stdout.read.strip }.sort
      errors = processes.map { |_stdin, _stdout, stderr, _wait| stderr.read }
      statuses = processes.map { |_stdin, _stdout, _stderr, wait| wait.value }

      assert_equal %w[0 1], outcomes
      assert statuses.all?(&:success?), errors.join
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
    assert subject.acknowledge(record, :request_delivery)
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
      attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
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
