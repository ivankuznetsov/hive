require "test_helper"
require "hive/daemon/dispatch_request_queue"
require "hive/attempts/finalization_maintenance"
require "hive/attempts/log_archive"
require "hive/task_action"

class AttemptsFinalizationMaintenanceTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  CAPABILITY = "c" * 64

  def test_proof_and_indexes_survive_a_crash_before_pending_publication
    with_store do |store|
      terminal = terminal_attempt(store)
      maintenance = maintenance(store)
      pending = store.pending_finalizations
      pending.define_singleton_method(:create) do |**|
        raise Hive::Attempts::StoreError, "injected pending crash"
      end

      assert_raises(Hive::Attempts::StoreError) { maintenance.prepare(terminal) }

      assert_equal terminal.to_h, store.fetch_hot(terminal.attempt_id).to_h
      assert_equal terminal.to_h, store.permanent_proofs.fetch(terminal.attempt_id).to_h
      assert_equal terminal.attempt_id,
                   store.decision_index.terminal_attempt_id(request_id: terminal["request_id"])
      assert_nil store.pending_finalizations.fetch(terminal.attempt_id)
    end
  end

  def test_partial_acknowledgements_resume_and_remove_hot_only_when_complete
    with_store do |store|
      terminal = terminal_attempt(store)
      maintenance = maintenance(store)

      assert maintenance.prepare(terminal)
      pending = store.pending_finalizations.fetch(terminal.attempt_id)
      assert_equal true, pending.dig("consumers", "accounting")
      assert_equal false, pending.dig("consumers", "journal")
      assert_equal false, pending.dig("consumers", "request_delivery")
      refute maintenance.promote(terminal)
      assert store.fetch_hot(terminal.attempt_id)

      maintenance.acknowledge(terminal, :journal)
      restarted = maintenance(store)
      restarted.acknowledge(terminal, :request_delivery)
      assert restarted.promote(terminal)

      assert_nil store.fetch_hot(terminal.attempt_id)
      assert_nil store.pending_finalizations.fetch(terminal.attempt_id)
      assert_equal terminal.to_h, store.fetch(terminal.attempt_id).to_h
      refute_includes store.decision_index.live_reservations.keys, terminal.attempt_id
    end
  end

  def test_unresolved_loss_stays_hot_and_resolved_loss_promotes
    with_store do |store|
      lost = store.mark_lost(
        create_attempt(store), reason: "launch_timeout", now: NOW + 1
      )
      maintenance = maintenance(store)

      refute maintenance.prepare(lost)
      assert store.fetch_hot(lost.attempt_id)
      assert_nil store.permanent_proofs.fetch(lost.attempt_id)

      outcome_store = Hive::Attempts::LostOutcomeStore.new(store: store)
      outcome_store.ensure_for(lost, now: NOW + 2)
      successor = create_attempt(
        store, attempt_id: "attempt-2", request_id: "request-2",
        predecessor_attempt_id: lost.attempt_id, now: NOW + 2
      )
      store.decision_index.record_successor(successor)
      outcome_store.update(
        lost, now: NOW + 3, status: "successor_dispatched",
        cleanup: "no_worker", successor_attempt_id: successor.attempt_id,
        diagnostic: nil
      )

      assert maintenance.prepare(store.fetch_hot(lost.attempt_id))
      maintenance.acknowledge(lost, :journal)
      maintenance.acknowledge(lost, :request_delivery)
      assert maintenance.promote(lost)
      assert_nil store.fetch_hot(lost.attempt_id)
      assert_equal successor.attempt_id,
                   store.decision_index.successor_attempt_id(
                     predecessor_attempt_id: lost.attempt_id
                   )
    end
  end

  def test_completed_pending_cleanup_is_idempotent_when_hot_removal_crashes
    with_store do |store|
      terminal = terminal_attempt(store)
      maintenance = maintenance(store)
      maintenance.prepare(terminal)
      maintenance.acknowledge(terminal, :journal)
      maintenance.acknowledge(terminal, :request_delivery)
      original_remove = store.method(:remove_hot_final)
      store.define_singleton_method(:remove_hot_final) do |_record|
        raise Hive::Attempts::StoreError, "injected hot removal crash"
      end

      assert_raises(Hive::Attempts::StoreError) { maintenance.promote(terminal) }
      assert_nil store.pending_finalizations.fetch(terminal.attempt_id)
      assert store.fetch_hot(terminal.attempt_id)

      store.define_singleton_method(:remove_hot_final, original_remove)
      assert maintenance.prepare(store.fetch_hot(terminal.attempt_id))
      maintenance.acknowledge(terminal, :journal)
      maintenance.acknowledge(terminal, :request_delivery)
      assert maintenance.promote(terminal)
      assert_nil store.fetch_hot(terminal.attempt_id)
    end
  end

  def test_active_log_writer_keeps_completed_finalization_hot
    with_store do |store|
      terminal = terminal_attempt(store)
      writer = store.log_archive.open_writer(terminal.attempt_id, clock: -> { NOW })
      writer.append(:stdout, "still open\n")
      maintenance = maintenance(store)
      maintenance.prepare(terminal)
      maintenance.acknowledge(terminal, :journal)
      maintenance.acknowledge(terminal, :request_delivery)

      refute maintenance.promote(terminal)
      assert store.fetch_hot(terminal.attempt_id)
      assert File.file?(store.log_archive.hot_path(terminal.attempt_id))
      refute File.exist?(store.log_archive.cold_path(terminal.attempt_id))

      writer.close
      assert maintenance.promote(terminal)
      assert File.file?(store.log_archive.cold_path(terminal.attempt_id))
    ensure
      writer&.close unless writer&.closed?
    end
  end

  def test_three_day_and_canonical_archive_log_expiry_preserve_proof
    with_store do |store|
      aged = terminal_attempt(
        store, attempt_id: "aged", request_id: "aged-request", write_log: true
      )
      archived = terminal_attempt(
        store, attempt_id: "archived", request_id: "archived-request",
        now: NOW + 60, write_log: true
      )
      maintenance = maintenance(
        store, task_archived: ->(record) { record.attempt_id == archived.attempt_id }
      )
      [ aged, archived ].each do |record|
        maintenance.prepare(record)
        maintenance.acknowledge(record, :journal)
        maintenance.acknowledge(record, :request_delivery)
        assert maintenance.promote(record)
      end

      assert_equal 1, maintenance.sweep_logs(now: NOW + 120).fetch(:deleted)
      assert_equal :available, store.log_archive.resolve(aged.attempt_id).availability
      assert_equal :expired, store.log_archive.resolve(archived.attempt_id).availability
      assert_equal 1,
                   maintenance.sweep_logs(now: NOW + (3 * 86_400) + 4).fetch(:deleted)
      assert store.fetch(aged.attempt_id).receipt
      assert store.fetch(archived.attempt_id).receipt
    end
  end

  def test_missing_or_noncanonical_done_task_falls_back_to_age
    with_store do |store|
      terminal = terminal_attempt(store, write_log: true)
      maintenance = maintenance(store, task_archived: ->(_record) { nil })
      maintenance.prepare(terminal)
      maintenance.acknowledge(terminal, :journal)
      maintenance.acknowledge(terminal, :request_delivery)
      assert maintenance.promote(terminal)

      assert_equal 0, maintenance.sweep_logs(now: NOW + 86_400).fetch(:deleted)
      assert_equal :available, store.log_archive.resolve(terminal.attempt_id).availability
      assert_equal 1,
                   maintenance.sweep_logs(now: NOW + (3 * 86_400) + 4).fetch(:deleted)
    end
  end

  def test_canonical_task_action_not_folder_name_controls_early_expiry
    with_store do |store|
      state_root = File.join(File.dirname(store.root), "state")
      folder = File.join(state_root, "stages", "9-done", "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- COMPLETE -->\n")
      task = Struct.new(:id, :state_file, :project_root).new("42", state_file, "/demo")
      marker = Struct.new(:name).new(:complete)
      action = Struct.new(:key).new(Hive::Schemas::TaskActionKind::READY_TO_ARCHIVE)
      maintenance = Hive::Attempts::FinalizationMaintenance.new(store: store)

      with_replaced_singleton_method(
        Hive::Config, :find_project,
        ->(_name) { { "hive_state_path" => state_root } }
      ) do
        with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { task }) do
          with_replaced_singleton_method(Hive::Markers, :current, ->(_path) { marker }) do
            with_replaced_singleton_method(Hive::Config, :load, ->(_root) { {} }) do
              with_replaced_singleton_method(Hive::TaskAction, :for, ->(*_args, **_kwargs) { action }) do
                refute maintenance.send(:task_archived?, terminal_attempt(store))
                action.key = Hive::Schemas::TaskActionKind::ARCHIVED
                assert maintenance.send(:task_archived?, store.fetch_hot("attempt-1"))
              end
            end
          end
        end
      end
    end
  end

  def test_due_stamped_foreground_catch_up_runs_at_most_hourly
    with_store do |store|
      terminal = terminal_attempt(store, write_log: true)
      observer = Object.new
      observer.define_singleton_method(:observe) { |_status, now:| :not_applicable }
      maintenance = maintenance(store, condition_observer: observer)

      first = maintenance.run_if_due(now: NOW + 10)
      second = maintenance.run_if_due(now: NOW + 20)

      assert_equal true, first.fetch(:ran)
      assert_equal 1, first.fetch(:promoted)
      assert_equal false, second.fetch(:ran)
      assert_nil store.fetch_hot(terminal.attempt_id)
      assert store.fetch(terminal.attempt_id).receipt
      status = store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "healthy", status.fetch("status")
      assert_equal 1, status.dig("maintenance", "last_result", "promoted")
      assert_equal 1, status.dig("maintenance", "last_result", "cold_examined")
    end
  end

  def test_due_cold_sweep_is_fixed_size_even_with_thirty_thousand_logs
    attempt_ids = 30_000.times.map { |index| "cold-#{index}" }
    cursor = { "shard" => 0, "after" => nil }
    archive = Object.new
    archive.define_singleton_method(:cold_attempt_ids_page) do |cursor:, limit:|
      raise "unexpected cursor" unless cursor == { "shard" => 0, "after" => nil }

      Hive::Attempts::LogArchive::ColdPage.new(
        attempt_ids: attempt_ids.first(limit),
        cursor: { "shard" => 4, "after" => attempt_ids.fetch(limit - 1) }
      )
    end
    health = Object.new
    health.define_singleton_method(:cold_sweep_cursor) { cursor }
    health.define_singleton_method(:advance_cold_sweep) { |value| cursor = value }
    store = Object.new
    store.define_singleton_method(:log_archive) { archive }
    store.define_singleton_method(:storage_health) { health }
    store.define_singleton_method(:fetch) { |_attempt_id| nil }
    maintenance = Hive::Attempts::FinalizationMaintenance.new(store: store)

    result = maintenance.sweep_logs(now: NOW)

    assert_equal Hive::Attempts::FinalizationMaintenance::COLD_SWEEP_LIMIT,
                 result.fetch(:cold_examined)
    assert_equal "cold-511", cursor.fetch("after")
  end

  def test_failed_maintenance_degrades_health_and_a_later_success_clears_it
    with_store do |store|
      archive = store.log_archive
      original = archive.method(:cold_attempt_ids_page)
      archive.define_singleton_method(:cold_attempt_ids_page) do |**|
        raise Hive::Attempts::StoreError, "cold archive unavailable"
      end
      maintenance = maintenance(store)

      assert_raises(Hive::Attempts::StoreError) do
        maintenance.run_if_due(now: NOW)
      end
      failed = store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "degraded", failed.fetch("status")
      assert_equal "maintenance_failed", failed.fetch("degraded_reason")

      archive.define_singleton_method(:cold_attempt_ids_page, original)
      result = maintenance.run_if_due(
        now: NOW + Hive::Attempts::FinalizationMaintenance::MAINTENANCE_INTERVAL_SEC
      )
      assert result.fetch(:ran)
      recovered = store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "healthy", recovered.fetch("status")
      assert_nil recovered.fetch("degraded_reason")
    end
  end

  def test_runtime_delivery_probe_matches_the_exact_claimed_attempt
    with_store do |store|
      terminal = terminal_attempt(store)
      claims = [
        Struct.new(:claim).new({ "attempt_id" => "another-attempt" }),
        Struct.new(:claim).new({ "attempt_id" => terminal.attempt_id })
      ]
      observed_state_home = nil

      with_replaced_singleton_method(
        Hive::Daemon::DispatchRequestQueue, :claimed,
        lambda { |state_home:|
          observed_state_home = state_home
          claims
        }
      ) do
        runtime = Hive::Attempts::FinalizationMaintenance.runtime(
          store: store, state_home: "/state"
        )

        assert runtime.send(:delivery_pending?, terminal)
      end

      assert_equal "/state", observed_state_home
    end
  end

  def test_promotion_rejects_a_mismatched_permanent_proof
    with_store do |store|
      terminal = terminal_attempt(store)
      service = Hive::Attempts::FinalizationMaintenance.new(store: store)
      service.prepare(terminal)
      service.acknowledge(terminal, :journal)
      service.acknowledge(terminal, :request_delivery)
      mismatched = Object.new
      mismatched.define_singleton_method(:to_h) do
        terminal.to_h.merge("attempt_id" => "another-attempt")
      end
      store.permanent_proofs.define_singleton_method(:fetch) { |_attempt_id| mismatched }

      error = assert_raises(Hive::Attempts::StoreError) { service.promote(terminal) }

      assert_match(/proof does not match/, error.message)
      assert store.fetch_hot(terminal.attempt_id)
      assert store.pending_finalizations.fetch(terminal.attempt_id)
    end
  end

  def test_promotion_rejects_a_hot_record_changed_after_proof_publication
    with_store do |store|
      terminal = terminal_attempt(store)
      changed = terminal_attempt(
        store, attempt_id: "attempt-2", request_id: "request-2", now: NOW + 10
      )
      service = maintenance(store)
      service.prepare(terminal)
      service.acknowledge(terminal, :journal)
      service.acknowledge(terminal, :request_delivery)
      store.define_singleton_method(:fetch_hot) { |_attempt_id| changed }

      error = assert_raises(Hive::Attempts::StoreError) { service.promote(terminal) }

      assert_match(/changed after final proof/, error.message)
      assert store.pending_finalizations.fetch(terminal.attempt_id)
    end
  end

  def test_due_sweep_records_a_degraded_health_result_when_archive_scan_fails
    with_store do |store|
      store.log_archive.define_singleton_method(:cold_attempt_ids_page) do |**|
        raise Hive::Attempts::StoreError, "cold archive unavailable"
      end
      service = maintenance(store)

      assert_raises(Hive::Attempts::StoreError) do
        service.sweep_if_due(now: NOW)
      end

      status = store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "degraded", status.fetch("status")
      assert_equal "maintenance_failed", status.fetch("degraded_reason")
    end
  end

  def test_delivery_probe_errors_keep_finalization_pending_for_retry
    with_store do |store|
      terminal = terminal_attempt(store)
      observer = Object.new
      observer.define_singleton_method(:observe) { |_status, now:| :delivered }
      service = Hive::Attempts::FinalizationMaintenance.new(
        store: store,
        condition_observer: observer,
        delivery_pending: ->(_record) { raise Hive::Attempts::StoreError, "queue unavailable" },
        task_archived: ->(_record) { false }
      )

      refute service.finalize(terminal, now: NOW + 4)

      pending = store.pending_finalizations.fetch(terminal.attempt_id)
      assert_equal true, pending.dig("consumers", "journal")
      assert_equal false, pending.dig("consumers", "request_delivery")
      assert store.fetch_hot(terminal.attempt_id)
    end
  end

  def test_incomplete_or_unreadable_pending_state_pins_cold_logs
    with_store do |store|
      incomplete = terminal_attempt(store, write_log: true)
      unreadable = terminal_attempt(
        store, attempt_id: "attempt-2", request_id: "request-2",
        now: NOW + 10, write_log: true
      )
      service = maintenance(store)
      service.prepare(incomplete)
      assert_equal :archived, store.log_archive.archive(incomplete.attempt_id)
      assert_equal :archived, store.log_archive.archive(unreadable.attempt_id)
      pending = store.pending_finalizations
      original_complete = pending.method(:complete?)
      pending.define_singleton_method(:complete?) do |attempt_id|
        raise Hive::Attempts::StoreError, "pending state unreadable" if attempt_id == unreadable.attempt_id

        original_complete.call(attempt_id)
      end

      result = service.sweep_logs(now: NOW + (4 * 86_400))

      assert_equal 0, result.fetch(:deleted)
      assert_equal :available, store.log_archive.resolve(incomplete.attempt_id).availability
      assert_equal :available, store.log_archive.resolve(unreadable.attempt_id).availability
    end
  end

  def test_invalid_end_time_and_archive_lookup_errors_fail_closed
    with_store do |store|
      terminal = terminal_attempt(store)
      service = Hive::Attempts::FinalizationMaintenance.new(store: store)

      refute service.send(:retention_expired?, { "ended_at" => "not-a-time" }, now: NOW)

      state_root = File.join(File.dirname(store.root), "state")
      broken_folder = File.join(state_root, "stages", "4-execute", terminal["task_slug"])
      valid_folder = File.join(state_root, "stages", "9-done", terminal["task_slug"])
      FileUtils.mkdir_p([ broken_folder, valid_folder ])
      task = Struct.new(:id, :state_file, :project_root).new(
        terminal["task_id"], File.join(valid_folder, "task.md"), "/demo"
      )
      marker = Struct.new(:name).new(:complete)
      action = Struct.new(:key).new(Hive::Schemas::TaskActionKind::ARCHIVED)
      archive_calls = []
      assert_equal [ broken_folder, valid_folder ].sort,
                   Dir.glob(File.join(state_root, "stages", "*", terminal["task_slug"])).sort

      with_replaced_singleton_method(
        Hive::Config, :find_project,
        lambda { |name|
          archive_calls << [ :project, name ]
          { "hive_state_path" => state_root }
        }
      ) do
        with_replaced_singleton_method(
          Hive::Task, :new,
          lambda { |folder|
            archive_calls << [ :task, folder ]
            raise Hive::InvalidTaskPath if folder == broken_folder

            task
          }
        ) do
          with_replaced_singleton_method(Hive::Markers, :current, ->(_path) { marker }) do
            with_replaced_singleton_method(Hive::Config, :load, ->(_root) { {} }) do
              with_replaced_singleton_method(
                Hive::TaskAction, :for,
                lambda { |*_args, **_kwargs|
                  archive_calls << [ :action ]
                  action
                }
              ) do
                assert service.send(:task_archived?, terminal), archive_calls.inspect
              end
            end
          end
        end
      end

      with_replaced_singleton_method(
        Hive::Config, :find_project, ->(_name) { raise KeyError, "project unavailable" }
      ) do
        refute service.send(:task_archived?, terminal)
      end
    end
  end

  def test_tempfail_finalization_refunds_daily_admission_accounting
    with_store do |store|
      terminal = terminal_attempt(store, exit_status: Hive::ExitCodes::TEMPFAIL)

      assert maintenance(store).prepare(terminal)

      assert_equal 0,
                   store.decision_index.daily_count(project: "demo", date: NOW.to_date)
    end
  end

  def test_corrupt_loss_outcome_cannot_make_a_lost_attempt_finalizable
    with_store do |store|
      lost = store.mark_lost(
        create_attempt(store), reason: "launch_timeout", now: NOW + 1
      )
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      outcomes.ensure_for(lost, now: NOW + 2)
      File.write(outcomes.send(:path, lost.attempt_id), "{")

      refute maintenance(store).prepare(lost)

      assert store.fetch_hot(lost.attempt_id)
      assert_nil store.permanent_proofs.fetch(lost.attempt_id)
    end
  end

  private

  def with_store
    with_tmp_dir do |root|
      yield Hive::Attempts::Store.new(root: File.join(root, "attempts"))
    end
  end

  def maintenance(store, **options)
    Hive::Attempts::FinalizationMaintenance.new(
      store: store,
      delivery_pending: ->(_record) { false },
      task_archived: ->(_record) { false },
      **options
    )
  end

  def create_attempt(store, attempt_id: "attempt-1", request_id: "request-1",
                     predecessor_attempt_id: nil, now: NOW)
    store.create_launching(
      attempt_id: attempt_id, request_id: request_id,
      predecessor_attempt_id: predecessor_attempt_id,
      task_id: "42", project: "demo", task_slug: "task",
      intended_stage: "4-execute", task_generation: "generation-1",
      ownership_generation: "generation-1", task_input_epoch: 1,
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: now
    )
  end

  def terminal_attempt(store, attempt_id: "attempt-1", request_id: "request-1",
                       now: NOW, write_log: false, exit_status: 0)
    launching = create_attempt(
      store, attempt_id: attempt_id, request_id: request_id, now: now
    )
    if write_log
      writer = store.log_archive.open_writer(attempt_id, clock: -> { now })
      writer.append(:stdout, "done\n")
      writer.close
    end
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid },
      claim_capability: CAPABILITY, first_heartbeat_timeout_sec: 30,
      now: now + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now + 2)
    store.terminalize(
      running, outcome: exit_status.zero? ? "succeeded" : "failed",
      exit_status: exit_status,
      final_checkpoint: running.checkpoint, output_references: [],
      log_reference: {
        "path" => "logs/#{attempt_id}.frames", "size" => 0,
        "sha256" => Digest::SHA256.hexdigest("")
      },
      now: now + 3
    )
  end
end
