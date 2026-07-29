require "test_helper"
require "hive/modules/migration/occurrence_journal"

class ModulesMigrationOccurrenceJournalTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_sender_recovery_state_contains_no_liveness_claims
    with_journal do |journal|
      first = effect_intent
      alternate = effect_intent(capability: "github_pull_requests:alternate")
      journal.prepare_effect!(first, now: NOW)
      journal.prepare_effect!(alternate, now: NOW)
      assert_equal [ first.occurrence_id ],
                   journal.each_reserved.map { |record| record.fetch("occurrence_id") }
      assert_equal 1, journal.each_record.count
      refute journal.projection_pending?
      journal.reserve!(patrol_capture, now: NOW)

      journal.mark_dispatch_uncertain!(first, now: NOW + 12)
      uncertain = journal.effect_state(first)
      assert_equal "dispatch_uncertain", uncertain.fetch("state")
      refute_includes uncertain, "claim"
      refute_includes uncertain, "delivery_generation"
      journal.reset_effect_prepared!(first, now: NOW + 13)
      journal.mark_dispatch_uncertain!(first, now: NOW + 13)
      outcome = { "url" => "https://example.test/effect/1" }
      committed = journal.settle_effect!(
        first,
        status: "committed",
        outcome: outcome,
        now: NOW + 14
      )

      assert_equal committed.to_h, journal.receipt(
        committed.receipt_id, occurrence_id: first.occurrence_id
      ).to_h
      assert_equal [ committed.receipt_id ],
                   journal.effect_receipt_ids(first.occurrence_id)
      assert_equal [ committed.receipt_id ],
                   journal.effect_state(first).fetch("receipt_ids")
    end
  end

  def test_recovery_active_is_one_view_for_reserved_and_pending_projection
    with_journal do |journal|
      occurrence_id = patrol_capture.occurrence_id
      assert_equal [ occurrence_id ],
                   journal.each_recovery_active.map { |record|
                     record.fetch("occurrence_id")
                   }

      journal.finalize!(
        terminal_capture(patrol_capture), now: NOW + 1
      )
      assert_equal [ occurrence_id ],
                   journal.each_recovery_active.map { |record|
                     record.fetch("occurrence_id")
                   }

      journal.pending_outbox(occurrence_id).each do |entry|
        journal.acknowledge_outbox!(
          occurrence_id,
          entry_id: entry.fetch("id"),
          digest: entry.fetch("digest")
        )
      end
      refute journal.recovery_active?
    end
  end

  def test_recovery_stream_drains_more_than_one_page_while_records_retire
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      count =
        Hive::Modules::Migration::OccurrenceRecordStore::MAX_PAGE_SIZE + 1
      captures = count.times.map do |index|
        window = NOW + index
        base = "ordinary:project-1:stream-#{index}"
        capture = schedule_capture(base, window: window, generation: 1)
        journal.reserve!(capture, now: window)
        journal.finalize!(
          terminal_capture(capture),
          now: window + 1
        )
        capture
      end
      recovered = []

      journal.each_recovery_active do |record|
        occurrence_id = record.fetch("occurrence_id")
        recovered << occurrence_id
        acknowledge_all(journal, occurrence_id)
      end

      assert_equal count, recovered.size
      assert_equal recovered, recovered.uniq
      assert_equal captures.map(&:occurrence_id).sort, recovered.sort
      assert_equal 0, journal.each_record.count
    end
  end

  def test_stable_sender_lock_blocks_other_processes_and_is_never_unlinked
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    with_journal do |journal|
      intent = effect_intent
      reader, writer = IO.pipe
      child = nil
      journal.with_effect_sender_lock(intent) do
        child = fork do
          reader.close
          journal.with_effect_sender_lock(intent) do
            writer.write("acquired")
            writer.flush
          end
          writer.close
          exit! 0
        end
        writer.close
        assert_nil IO.select([ reader ], nil, nil, 0.1)
      end
      assert IO.select([ reader ], nil, nil, 2)
      assert_equal "acquired", reader.read
      Process.wait(child)
      assert_predicate $?, :success?
      child = nil

      lock = Dir.glob(
        File.join(journal.root, ".sender-locks", "*.lock")
      ).fetch(0)
      assert_equal 0o600, File.stat(lock).mode & 0o777
      assert_path_exists lock
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      Process.wait(child) if child
    end
  end

  def test_stable_sender_lock_rejects_malformed_names
    with_tmp_dir do |root|
      lock = Hive::Modules::Migration::StableProcessLock.new(
        root: File.join(root, "locks"),
        label: "test locks"
      )
      assert_raises(Hive::ConfigError) do
        lock.synchronize("../escape") { flunk("must not lock") }
      end
    end
  end

  def test_schedule_attempt_generation_is_durable_and_concurrency_safe
    with_journal do |journal|
      base = "ordinary:project-1:2026-07-28T12:00:00.000000Z"
      captures = 2.times.map do
        Thread.new do
          journal.reserve_attempt!(
            base, window_started_at: NOW, now: NOW
          ) do |generation|
            patrol_capture(
              trigger: {
                "kind" => "schedule",
                "id" => "#{base}:attempt:#{generation}"
              },
              reservation: {
                "kind" => "ordinary",
                "id" => base,
                "window_started_at" => NOW.iso8601(6),
                "attempt_generation" => generation
              }
            )
          end
        end
      end.map(&:value)
      assert_equal 1, captures.map(&:occurrence_id).uniq.size
      assert_equal 1,
                   captures.first.reservation.fetch("attempt_generation")

      journal.finalize!(
        terminal_capture(captures.first), now: NOW + 1
      )
      retry_capture = journal.reserve_attempt!(
        base, window_started_at: NOW, now: NOW + 2
      ) do |generation|
        patrol_capture(
          trigger: {
            "kind" => "schedule",
            "id" => "#{base}:attempt:#{generation}"
          },
          reservation: {
            "kind" => "ordinary",
            "id" => base,
            "window_started_at" => NOW.iso8601(6),
            "attempt_generation" => generation
          }
        )
      end
      assert_equal 2,
                   retry_capture.reservation.fetch("attempt_generation")
      refute_equal captures.first.occurrence_id,
                   retry_capture.occurrence_id
    end
  end

  def test_retirement_fences_negative_replay_but_allows_next_retry_generation
    with_tmp_dir do |root|
      journal_root = File.join(root, "occurrences")
      journal = occurrence_journal(journal_root)
      base = "ordinary:project-1:#{NOW.iso8601(6)}"
      provisional = schedule_capture(base, window: NOW, generation: 1)
      journal.reserve!(provisional, now: NOW)
      journal.finalize!(
        terminal_capture(provisional), now: NOW + 1
      )
      acknowledge_all(journal, provisional.occurrence_id)

      assert_nil journal.fetch(provisional.occurrence_id)
      restarted = occurrence_journal(journal_root)
      assert_raises(Hive::ConfigError) do
        restarted.reserve!(provisional, now: NOW + 2)
      end

      retry_capture = restarted.reserve_attempt!(
        base, window_started_at: NOW, now: NOW + 3
      ) do |generation|
        schedule_capture(base, window: NOW, generation: generation)
      end
      assert_equal 2,
                   retry_capture.reservation.fetch("attempt_generation")
      refute_equal provisional.occurrence_id, retry_capture.occurrence_id
    end
  end

  def test_retirement_fences_non_attempt_occurrences_for_both_products
    [
      [ "patrol", patrol_capture ],
      [ "architecture-patrol", architecture_capture ]
    ].each do |module_name, provisional|
      with_tmp_dir do |root|
        journal_root = File.join(root, "occurrences")
        journal = Hive::Modules::Migration::OccurrenceJournal.new(
          journal_root, module_name: module_name
        )
        journal.reserve!(provisional, now: NOW)
        journal.finalize!(
          terminal_capture(provisional), now: NOW + 1
        )
        acknowledge_all(journal, provisional.occurrence_id)
        assert_nil journal.fetch(provisional.occurrence_id)

        restarted = Hive::Modules::Migration::OccurrenceJournal.new(
          journal_root, module_name: module_name
        )
        assert_raises(Hive::ConfigError) do
          restarted.reserve!(provisional, now: NOW + 2)
        end
      end
    end
  end

  def test_full_retirement_fence_keeps_terminal_record_authoritative
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      first = patrol_capture
      second = patrol_capture(
        trigger: { "kind" => "manual", "id" => "second" }
      )
      third = patrol_capture(
        trigger: { "kind" => "manual", "id" => "third" }
      )
      with_constant(
        Hive::Modules::Migration::OccurrenceJournalState,
        :MAX_RETIRED_OCCURRENCES,
        1
      ) do
        journal.reserve!(first, now: NOW)
        journal.finalize!(
          terminal_capture(first), now: NOW + 1
        )
        acknowledge_all(journal, first.occurrence_id)

        journal.reserve!(second, now: NOW + 2)
        journal.finalize!(
          terminal_capture(second), now: NOW + 3
        )
        acknowledge_all(journal, second.occurrence_id)
        retained = journal.fetch(second.occurrence_id)
        assert_equal "finalized", retained.fetch("phase")
        assert retained.fetch("outbox").all? {
          |entry| entry.fetch("acknowledged")
        }

        with_constant(
          Hive::Modules::Migration::OccurrenceRecordStore,
          :MAX_HISTORY_RECORDS,
          1
        ) do
          assert_raises(Hive::ConfigError) do
            journal.reserve!(third, now: NOW + 4)
          end
        end
        assert journal.fetch(second.occurrence_id)
      end
    end
  end

  def test_high_water_compaction_survives_restarts_and_rejects_old_windows
    with_tmp_dir do |root|
      journal_root = File.join(root, "occurrences")
      windows = 3.times.map { |index| NOW + (index * 600) }
      with_constant(
        Hive::Modules::Migration::OccurrenceJournalState,
        :MAX_SEQUENCE_HIGH_WATERS,
        2
      ) do
        windows.each do |window|
          journal = occurrence_journal(journal_root)
          base = "ordinary:project-1:#{window.iso8601(6)}"
          capture = journal.reserve_attempt!(
            base, window_started_at: window, now: window
          ) do |generation|
            schedule_capture(
              base, window: window, generation: generation
            )
          end
          journal.finalize!(
            terminal_capture(capture), now: window + 1
          )
          acknowledge_all(journal, capture.occurrence_id)
          assert_nil occurrence_journal(journal_root).fetch(
            capture.occurrence_id
          )
        end

        state = JSON.parse(
          File.binread(File.join(journal_root, "journal-state.json"))
        )
        assert_equal 2, state.fetch("sequence_high_waters").size
        assert_equal windows.first.iso8601(6),
                     state.fetch("sequence_closed_through")

        restarted = occurrence_journal(journal_root)
        stale_base =
          "ordinary:project-1:#{windows.first.iso8601(6)}"
        assert_raises(Hive::ConfigError) do
          restarted.reserve_attempt!(
            stale_base,
            window_started_at: windows.first,
            now: windows.last + 2
          ) do
            flunk("an evicted closed window must stay retired")
          end
        end

        new_window = windows.last + 600
        new_base = "ordinary:project-1:#{new_window.iso8601(6)}"
        admitted = restarted.reserve_attempt!(
          new_base, window_started_at: new_window, now: new_window
        ) do |generation|
          schedule_capture(
            new_base, window: new_window, generation: generation
          )
        end
        assert_equal 1,
                     admitted.reservation.fetch("attempt_generation")
      end
    end
  end

  def test_active_cap_never_retires_reserved_or_unacknowledged_work
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      first = patrol_capture
      second = patrol_capture(
        trigger: { "kind" => "manual", "id" => "second" }
      )
      third = patrol_capture(
        trigger: { "kind" => "manual", "id" => "third" }
      )
      journal.reserve!(first, now: NOW)
      journal.reserve!(second, now: NOW)

      with_constant(
        Hive::Modules::Migration::OccurrenceRecordStore,
        :MAX_HISTORY_RECORDS,
        2
      ) do
        journal.finalize!(
          terminal_capture(first), now: NOW + 1
        )
        assert_raises(Hive::ConfigError) do
          journal.reserve!(third, now: NOW + 2)
        end
        assert journal.fetch(first.occurrence_id)
        assert journal.fetch(second.occurrence_id)

        acknowledge_all(journal, first.occurrence_id)
        assert_nil journal.fetch(first.occurrence_id)
        assert journal.reserve!(third, now: NOW + 3)
        assert journal.fetch(second.occurrence_id)
      end
    end
  end

  def test_recovery_backoff_is_durable_and_compare_and_set_cleared
    with_tmp_dir do |root|
      journal_root = File.join(root, "occurrences")
      first = occurrence_journal(journal_root).record_recovery_failure!(
        operation: "projection",
        occurrence_id: patrol_capture.occurrence_id,
        error: RuntimeError.new("boom"),
        now: NOW
      )
      assert_equal 1, first.fetch("generation")
      assert_equal 1, first.fetch("failure_count")
      assert_equal (NOW + 60).iso8601(6),
                   first.fetch("next_eligible_at")

      restarted = occurrence_journal(journal_root)
      assert restarted.recovery_backoff(now: NOW + 30).fetch("blocked")
      second = restarted.record_recovery_failure!(
        operation: "projection",
        occurrence_id: patrol_capture.occurrence_id,
        error: RuntimeError.new("boom again"),
        now: NOW + 61
      )
      assert_equal 2, second.fetch("generation")
      assert_equal 2, second.fetch("failure_count")
      assert_equal (NOW + 361).iso8601(6),
                   second.fetch("next_eligible_at")

      refute occurrence_journal(journal_root).clear_recovery_failure!(
        expected_generation: first.fetch("generation")
      )
      current = occurrence_journal(journal_root).recovery_backoff(
        now: NOW + 62
      )
      assert_equal second.fetch("generation"),
                   current.dig("failure", "generation")
      assert occurrence_journal(journal_root).clear_recovery_failure!(
        expected_generation: second.fetch("generation")
      )
      refute occurrence_journal(journal_root).recovery_backoff(
        now: NOW + 62
      ).fetch("blocked")
    end
  end

  def test_recovery_failure_normalizes_unicode_and_anonymous_errors
    with_tmp_dir do |root|
      journal_root = File.join(root, "occurrences")
      invalid_message = (
        ("\u2603" * 300).b + "\xFF".b
      ).force_encoding(Encoding::UTF_8)
      anonymous_error = Class.new(StandardError).new(invalid_message)
      failure = occurrence_journal(journal_root)
                .record_recovery_failure!(
                  operation: "projection",
                  error: anonymous_error,
                  now: NOW
                )

      assert_equal "AnonymousError", failure.fetch("error_class")
      message = failure.fetch("error_message")
      assert message.valid_encoding?
      assert_operator message.bytesize, :<=,
                      Hive::Modules::Migration::OccurrenceJournalState::
                        MAX_ERROR_BYTES
      persisted = occurrence_journal(journal_root).recovery_backoff(
        now: NOW
      ).fetch("failure")
      assert_equal failure, persisted

      named_error = Class.new(StandardError)
      named_error.define_singleton_method(:name) { "\u03A9" * 200 }
      bounded = occurrence_journal(journal_root)
                .record_recovery_failure!(
                  operation: "other-projection",
                  error: named_error.new("bounded"),
                  now: NOW + 1
                )
      assert bounded.fetch("error_class").valid_encoding?
      assert_operator bounded.fetch("error_class").bytesize, :<=,
                      Hive::Modules::Migration::OccurrenceJournalState::
                        MAX_ERROR_CLASS_BYTES
      assert_equal bounded,
                   occurrence_journal(journal_root).recovery_backoff(
                     now: NOW + 1
                   ).fetch("failure")
    end
  end

  def test_reserve_attempt_composes_locks_in_the_declared_order
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      events = []
      stack = []
      trace_journal_locks(journal, events: events, stack: stack)
      base = "ordinary:project-1:#{NOW.iso8601(6)}"

      journal.reserve_attempt!(
        base, window_started_at: NOW, now: NOW
      ) do |generation|
        schedule_capture(base, window: NOW, generation: generation)
      end

      enters = events.select { |event| event.fetch(:event) == :enter }
      identity = enters.find { |event| event.fetch(:lock) == :identity }
      state = enters.find { |event| event.fetch(:lock) == :journal_state }
      inventory = enters.find { |event| event.fetch(:lock) == :inventory }
      record = enters.find { |event| event.fetch(:lock) == :record }
      assert_equal [], identity.fetch(:held)
      assert_equal [ :identity ], state.fetch(:held)
      assert_equal %i[identity journal_state], inventory.fetch(:held)
      assert_equal %i[identity journal_state inventory],
                   record.fetch(:held)
      assert_empty stack
    end
  end

  def test_reserve_attempt_consumes_single_pass_records_without_retaining_them
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      base = "ordinary:project-1:#{NOW.iso8601(6)}"
      expected = schedule_capture(base, window: NOW, generation: 1)
      journal.reserve!(expected, now: NOW)
      store = journal.instance_variable_get(:@store)
      original_each = store.method(:each_record)
      proxy_builder = method(:invalidating_record)
      store.define_singleton_method(:each_record) do |&block|
        return original_each.call unless block

        original_each.call do |record|
          proxy = proxy_builder.call(record)
          block.call(proxy)
          proxy.invalidate!
        end
      end

      actual = journal.reserve_attempt!(
        base, window_started_at: NOW, now: NOW + 1
      ) do
        flunk("the active reservation must be reused")
      end
      assert_equal expected.to_h, actual.to_h
    end
  end

  def test_identity_lock_files_remain_bounded_after_many_occurrences
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      72.times do |index|
        window = NOW + (index * 600)
        base = "ordinary:project-1:#{window.iso8601(6)}"
        journal.reserve_attempt!(
          base, window_started_at: window, now: window
        ) do |generation|
          schedule_capture(
            base, window: window, generation: generation
          )
        end
        journal.with_effect_sender_lock(
          effect_intent(target: "owner/demo:#{index}")
        ) { }
      end

      %w[.attempt-locks .record-locks .sender-locks].each do |relative|
        count = Dir.glob(
          File.join(journal.root, relative, "*.lock")
        ).size
        assert_operator count, :>, 1
        assert_operator count, :<=,
                        Hive::Modules::Migration::OccurrenceJournal::
                          LOCK_STRIPES
      end
      assert_equal 1, Dir.glob(
        File.join(journal.root, ".inventory-locks", "*.lock")
      ).size
      assert_equal 1, Dir.glob(
        File.join(journal.root, ".journal-state-locks", "*.lock")
      ).size
    end
  end

  def test_schedule_attempt_allocation_rejects_malformed_or_ambiguous_history
    with_journal do |journal|
      base = "ordinary:project-1:2026-07-28T12:00:00.000000Z"
      assert_raises(Hive::ConfigError) do
        journal.reserve_attempt!(
          base, window_started_at: NOW, now: NOW
        ) do |generation|
          patrol_capture(
            trigger: {
              "kind" => "schedule",
              "id" => "wrong:attempt:#{generation}"
            },
            reservation: {
              "kind" => "ordinary",
              "id" => "wrong",
              "window_started_at" => NOW.iso8601(6),
              "attempt_generation" => generation
            }
          )
        end
      end

      2.times do |index|
        generation = index + 1
        journal.reserve!(
          patrol_capture(
            trigger: {
              "kind" => "schedule",
              "id" => "#{base}:attempt:#{generation}"
            },
            reservation: {
              "kind" => "ordinary",
              "id" => base,
              "window_started_at" => NOW.iso8601(6),
              "attempt_generation" => generation
            }
          ),
          now: NOW
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.reserve_attempt!(
          base, window_started_at: NOW, now: NOW
        ) do
          flunk("ambiguous history must not allocate")
        end
      end
    end
  end

  def test_settlement_and_denial_conflicts_fail_closed
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)

      assert_raises(Hive::ConfigError) do
        journal.settle_effect!(
          intent,
          status: "unknown",
          outcome: {},
          now: NOW
        )
      end

      assert_raises(Hive::ConfigError) do
        journal.settle_effect!(
          intent,
          status: "committed",
          outcome: {},
          now: NOW
        )
      end

      denial = journal.deny_effect!(
        intent,
        outcome: { "reason" => "revoked" },
        now: NOW
      )
      replay = journal.deny_effect!(
        intent,
        outcome: { "reason" => "revoked" },
        now: NOW + 60
      )
      assert_equal denial.to_h, replay.to_h
      assert_equal "denied",
                   journal.effect_state(intent).fetch("state")
      assert_raises(Hive::ConfigError) do
        journal.deny_effect!(
          intent, outcome: { "reason" => "changed" }, now: NOW + 61
        )
      end

      uncertain = effect_intent(target: "owner/demo:uncertain")
      journal.prepare_effect!(uncertain, now: NOW)
      journal.mark_dispatch_uncertain!(uncertain, now: NOW)
      assert_raises(Hive::ConfigError) do
        journal.mark_dispatch_uncertain!(uncertain, now: NOW)
      end
      assert_raises(Hive::ConfigError) do
        journal.deny_effect!(
          uncertain, outcome: { "reason" => "revoked" }, now: NOW
        )
      end
    end
  end

  def test_reconciled_settlement_reuses_exact_persisted_receipt_bytes
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      journal.mark_dispatch_uncertain!(intent, now: NOW)
      outcome = { "remote" => "matched" }
      reconciled = journal.settle_effect!(
        intent,
        status: "reconciled",
        outcome: outcome,
        now: NOW + 2
      )
      replay = journal.settle_effect!(
        intent,
        status: "reconciled",
        outcome: outcome,
        now: NOW + 3
      )
      assert_equal reconciled.to_h, replay.to_h

      assert_raises(Hive::ConfigError) do
        journal.settle_effect!(
          intent,
          status: "reconciled",
          outcome: { "remote" => "different" },
          now: NOW + 4
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.settle_effect!(
          effect_intent(target: "other"),
          status: "reconciled",
          outcome: {},
          now: NOW
        )
      end
    end
  end

  def test_finalization_replay_uses_exact_capture_and_event_bytes
    with_journal do |journal|
      provisional = patrol_capture
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      assert_raises(Hive::ConfigError) do
        journal.finalize!(provisional, now: NOW)
      end
      drifted_time = Hive::Modules::Migration::PatrolCapture.build(
        module_name: provisional.module_name,
        project: provisional.project,
        trigger: provisional.trigger,
        reservation: provisional.reservation,
        owner: provisional.owner,
        owner_epoch: provisional.owner_epoch,
        selection_input: provisional.selection_input,
        selection: provisional.selection,
        outcome_class: "completed",
        outcome: { "rationale" => "completed" },
        occurred_at: NOW + 1,
        recorded_at: NOW + 1
      )
      assert_equal provisional.occurrence_id, drifted_time.occurrence_id
      assert_raises(Hive::ConfigError) do
        journal.finalize!(drifted_time, now: NOW + 1)
      end
      assert_equal [ provisional.occurrence_id ],
                   journal.each_reserved.map { |record| record.fetch("occurrence_id") }
      journal.mark_dispatch_uncertain!(intent, now: NOW)
      outcome = { "url" => "https://example.test/effect/1" }
      committed = journal.settle_effect!(
        intent,
        status: "committed",
        outcome: outcome,
        now: NOW
      )
      final = patrol_capture(
        outcome_class: "completed",
        outcome: { "rationale" => "completed" },
        effect_ids: [ committed.receipt_id ]
      )
      event = canonical(
        "event_id" => "evt-#{'a' * 64}",
        "payload" => { "capture" => final.to_h }
      )

      missing_effect = patrol_capture(
        outcome_class: "completed",
        outcome: { "rationale" => "completed" },
        effect_ids: []
      )
      assert_raises(Hive::ConfigError) do
        journal.finalize!(
          missing_effect, event_bytes: event, now: NOW + 1
        )
      end
      journal.finalize!(final, event_bytes: event, now: NOW + 1)
      replay = journal.finalize!(
        final, event_bytes: event, now: NOW + 2
      )
      assert_equal "finalized", replay.fetch("phase")
      assert_raises(Hive::ConfigError) do
        journal.prepare_effect!(
          effect_intent(target: "owner/demo:new"), now: NOW + 2
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.mark_dispatch_uncertain!(intent, now: NOW + 2)
      end
      pending_ids = journal.each_projection_pending.map do |record|
        record.fetch("occurrence_id")
      end
      assert_equal [ final.occurrence_id ], pending_ids
      assert_equal %w[capture event receipt],
                   replay.fetch("outbox").map { |entry| entry.fetch("kind") }
                         .sort

      conflicting = patrol_capture(
        outcome_class: "failed",
        outcome: { "rationale" => "failed" },
        effect_ids: [ committed.receipt_id ]
      )
      assert_equal provisional.occurrence_id, conflicting.occurrence_id
      assert_raises(Hive::ConfigError) do
        journal.finalize!(
          conflicting, event_bytes: event, now: NOW + 3
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.finalize!(
          final, event_bytes: canonical("payload" => {}),
          now: NOW + 3
        )
      end
    end
  end

  def test_provisional_capture_cannot_claim_terminal_effects
    with_tmp_dir do |root|
      journal = occurrence_journal(File.join(root, "occurrences"))
      provisional = patrol_capture(effect_ids: [ "receipt-forged" ])

      assert_raises(Hive::ConfigError) do
        journal.reserve!(provisional, now: NOW)
      end
      assert_equal 0, journal.each_record.count
    end
  end

  def test_outbox_acknowledgement_and_receipt_reads_reject_tampering
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      outcome = { "reason" => "revoked" }
      denied = journal.deny_effect!(
        intent, outcome: outcome, now: NOW
      )
      entry = journal.pending_outbox(intent.occurrence_id).fetch(0)

      assert_raises(Hive::ConfigError) do
        journal.acknowledge_outbox!(
          intent.occurrence_id,
          entry_id: entry.fetch("id"),
          digest: "wrong"
        )
      end
      journal.acknowledge_outbox!(
        intent.occurrence_id,
        entry_id: entry.fetch("id"),
        digest: entry.fetch("digest")
      )
      assert_empty journal.pending_outbox(intent.occurrence_id)
      assert_raises(Hive::ConfigError) do
        journal.receipt("receipt-#{'0' * 64}",
                        occurrence_id: intent.occurrence_id)
      end

      path = File.join(
        journal.root, "#{intent.occurrence_id}.json"
      )
      malformed = mutable(journal.fetch(intent.occurrence_id))
      receipt_entry = malformed.fetch("outbox").find do |candidate|
        candidate.fetch("id") == denied.receipt_id
      end
      receipt_entry["bytes"] = "{bad"
      receipt_entry["digest"] = Digest::SHA256.hexdigest("{bad")
      File.write(path, canonical(malformed))
      assert_raises(Hive::ConfigError) do
        journal.receipt(
          denied.receipt_id, occurrence_id: intent.occurrence_id
        )
      end
    end
  end

  def test_identity_and_input_guards
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)

      forged = Hive::Modules::Migration::EffectIntent.new(
        **intent.deconstruct_keys(nil).merge(capability: "forged")
      )
      assert_raises(Hive::ConfigError) do
        journal.prepare_effect!(forged, now: NOW)
      end

      assert_raises(Hive::ConfigError) do
        journal.fetch("bad")
      end
      assert_raises(Hive::ConfigError) do
        journal.mark_dispatch_uncertain!(
          effect_intent(target: "missing"), now: NOW
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.reset_effect_prepared!(intent, now: NOW
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.settle_effect!(
          intent, status: "committed", outcome: [], now: NOW
        )
      end
      validator = occurrence_validator
      assert_raises(Hive::ConfigError) do
        validator.object([], "object")
      end
      cyclic = {}
      cyclic["self"] = cyclic
      assert_raises(Hive::ConfigError) do
        validator.object(cyclic, "object")
      end
      assert_raises(Hive::ConfigError) do
        validator.canonical_bytes("{bad", "bytes")
      end
    end
  end

  def test_record_and_outbox_validation_reject_every_cross_binding
    with_journal do |journal|
      validator = occurrence_validator
      reserved = mutable(journal.fetch(patrol_capture.occurrence_id))
      other = patrol_capture(
        trigger: { "kind" => "manual", "id" => "other" }
      )

      wrong_capture = mutable(reserved)
      wrong_capture["provisional_capture"] = other.to_h
      assert_invalid_record(validator, wrong_capture)

      reserved_with_final = mutable(reserved)
      reserved_with_final["final_capture"] = patrol_capture.to_h
      assert_invalid_record(validator, reserved_with_final)
      finalized_with_wrong_capture = mutable(reserved).merge(
        "phase" => "finalized",
        "final_capture" => other.to_h
      )
      assert_invalid_record(validator, finalized_with_wrong_capture)

      prepared_intent = effect_intent
      journal.prepare_effect!(prepared_intent, now: NOW)
      prepared = mutable(journal.fetch(prepared_intent.occurrence_id))
      cell = prepared.fetch("effects").fetch(prepared_intent.intent_id)

      invalid_state = mutable(prepared)
      invalid_state.dig("effects", prepared_intent.intent_id)["state"] =
        "invalid"
      assert_invalid_record(validator, invalid_state)

      invalid_authorization = mutable(prepared)
      auths = invalid_authorization
              .dig("effects", prepared_intent.intent_id, "authorizations")
      auths["auth-#{'0' * 64}"] = auths.delete(
        prepared_intent.authorization_digest
      )
      assert_invalid_record(validator, invalid_authorization)

      missing_receipt = mutable(prepared)
      missing_receipt.dig(
        "effects", prepared_intent.intent_id, "receipt_ids"
      ) << "receipt-#{'0' * 64}"
      assert_invalid_record(validator, missing_receipt)

      inactive_claim = mutable(prepared)
      inactive_claim.dig("effects", prepared_intent.intent_id)["claim"] = {
        "token" => "token"
      }
      assert_invalid_record(validator, inactive_claim)

      legacy_generation = mutable(prepared)
      legacy_generation.dig(
        "effects", prepared_intent.intent_id
      )["delivery_generation"] = 1
      assert_invalid_record(validator, legacy_generation)

      oversized_effects = prepared.fetch("effects").to_h do |id, value|
        [ id, value ]
      end
      max = Hive::Modules::Migration::PatrolEvidence::
        MAX_EFFECTS_PER_OCCURRENCE
      (max + 1).times do |index|
        oversized_effects["intent-#{format('%064x', index + 1)}"] =
          mutable(cell)
      end
      oversized_record = mutable(prepared)
      oversized_record["effects"] = oversized_effects
      assert_invalid_record(validator, oversized_record)

      oversized_outbox = mutable(prepared)
      oversized_outbox["outbox"] = Array.new(
        Hive::Modules::Migration::OccurrenceContract::
          MAX_OUTBOX_ENTRIES + 1
      )
      assert_invalid_record(validator, oversized_outbox)

      malformed_entry = mutable(prepared)
      malformed_entry["outbox"] = [ { "kind" => "receipt" } ]
      malformed_entry["next_outbox_sequence"] = 2
      assert_invalid_record(validator, malformed_entry)

      event_bytes = canonical("event_id" => "evt-#{'a' * 64}")
      event_entry = outbox_entry(
        sequence: 1,
        kind: "event",
        id: "evt-#{'a' * 64}",
        bytes: event_bytes
      )
      duplicate_sequence = mutable(prepared)
      duplicate_sequence["outbox"] = [
        event_entry, event_entry.merge("sequence" => 1)
      ]
      duplicate_sequence["next_outbox_sequence"] = 3
      assert_invalid_record(validator, duplicate_sequence)

      wrong_event = mutable(prepared)
      wrong_event["outbox"] = [
        event_entry.merge("id" => "evt-#{'b' * 64}")
      ]
      wrong_event["next_outbox_sequence"] = 2
      assert_invalid_record(validator, wrong_event)

      wrong_capture_entry = outbox_entry(
        sequence: 1,
        kind: "capture",
        id: other.capture_id,
        bytes: canonical(other.to_h)
      )
      wrong_capture_record = mutable(prepared)
      wrong_capture_record["outbox"] = [ wrong_capture_entry ]
      wrong_capture_record["next_outbox_sequence"] = 2
      assert_invalid_record(validator, wrong_capture_record)

      wrong_intent = effect_intent(target: "other")
      wrong_receipt = receipt(wrong_intent, "denied", {})
      wrong_receipt_record = mutable(prepared)
      wrong_receipt_record["outbox"] = [
        outbox_entry(
          sequence: 1,
          kind: "receipt",
          id: "receipt-#{'0' * 64}",
          bytes: canonical(wrong_receipt.to_h)
        )
      ]
      wrong_receipt_record["next_outbox_sequence"] = 2
      assert_invalid_record(validator, wrong_receipt_record)

      unknown_kind = mutable(prepared)
      unknown_kind["outbox"] = [
        outbox_entry(
          sequence: 1,
          kind: "unknown",
          id: "id",
          bytes: canonical({})
        )
      ]
      unknown_kind["next_outbox_sequence"] = 2
      assert_invalid_record(validator, unknown_kind)

      malformed_bytes = mutable(prepared)
      malformed_bytes["outbox"] = [
        outbox_entry(
          sequence: 1,
          kind: "event",
          id: "id",
          bytes: "{bad"
        )
      ]
      malformed_bytes["next_outbox_sequence"] = 2
      assert_invalid_record(validator, malformed_bytes)

      assert_raises(Hive::ConfigError) do
        validator.receipt(wrong_receipt, intent: prepared_intent)
      end

      reserved_projection = mutable(reserved)
      reserved_projection["outbox"] = [
        outbox_entry(
          sequence: 1,
          kind: "capture",
          id: patrol_capture.capture_id,
          bytes: canonical(patrol_capture.to_h)
        )
      ]
      reserved_projection["next_outbox_sequence"] = 2
      assert_invalid_record(validator, reserved_projection)

      finalized = mutable(reserved).merge(
        "phase" => "finalized",
        "final_capture" => patrol_capture.to_h
      )
      assert_invalid_record(validator, finalized)

      nonterminal_with_receipt = mutable(cell)
      nonterminal_with_receipt["terminal_receipt_id"] =
        "receipt-#{'0' * 64}"
      invalid_nonterminal = mutable(prepared)
      invalid_nonterminal["effects"] = {
        prepared_intent.intent_id => nonterminal_with_receipt
      }
      assert_invalid_record(validator, invalid_nonterminal)

      orphan = receipt(prepared_intent, "denied", {})
      orphan_entry = outbox_entry(
        sequence: 1,
        kind: "receipt",
        id: orphan.receipt_id,
        bytes: canonical(orphan.to_h)
      )
      orphan_record = mutable(prepared)
      orphan_record["outbox"] = [ orphan_entry ]
      orphan_record["next_outbox_sequence"] = 2
      assert_invalid_record(validator, orphan_record)

      terminal_cell = mutable(cell)
      terminal_cell["state"] = "failed"
      terminal_cell["outcome"] = {}
      terminal_cell["receipt_ids"] = [ orphan.receipt_id ]
      terminal_cell["terminal_receipt_id"] = orphan.receipt_id
      terminal_mismatch = mutable(prepared)
      terminal_mismatch["effects"] = {
        prepared_intent.intent_id => terminal_cell
      }
      terminal_mismatch["outbox"] = [ orphan_entry ]
      terminal_mismatch["next_outbox_sequence"] = 2
      assert_invalid_record(validator, terminal_mismatch)

      finalized_nonterminal = mutable(prepared)
      finalized_nonterminal["phase"] = "finalized"
      finalized_nonterminal["final_capture"] = patrol_capture.to_h
      capture_bytes = canonical(patrol_capture.to_h)
      finalized_nonterminal["outbox"] = [
        outbox_entry(
          sequence: 1,
          kind: "capture",
          id: patrol_capture.capture_id,
          bytes: capture_bytes
        )
      ]
      finalized_nonterminal["next_outbox_sequence"] = 2
      assert_invalid_record(validator, finalized_nonterminal)

      malformed_module = mutable(prepared)
      malformed_module.delete("module")
      assert_invalid_record(validator, malformed_module)

      conflicting_semantic = mutable(prepared)
      conflicting_semantic.dig(
        "effects", prepared_intent.intent_id, "semantic"
      )["target"] = "other"
      assert_invalid_record(validator, conflicting_semantic)

      invalid_id = mutable(prepared)
      assert_raises(Hive::ConfigError) do
        validator.validate!(
          invalid_id,
          expected_id: "occ-#{'0' * 64}"
        )
      end
    end
  end

  def test_file_shape_size_and_store_bounds_fail_closed
    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      journal.reserve!(patrol_capture, now: NOW)
      path = File.join(
        journal.root, "#{patrol_capture.occurrence_id}.json"
      )

      File.write(path, JSON.pretty_generate(JSON.parse(File.read(path))))
      assert_raises(Hive::ConfigError) do
        journal.fetch(patrol_capture.occurrence_id)
      end
      File.write(path, "{bad")
      assert_raises(Hive::ConfigError) do
        journal.fetch(patrol_capture.occurrence_id)
      end
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      journal.reserve!(patrol_capture, now: NOW)
      path = File.join(
        journal.root, "#{patrol_capture.occurrence_id}.json"
      )
      other = File.join(root, "other")
      File.write(other, "{}")
      original = File.method(:open)
      replacement = lambda do |candidate, *args, **kwargs, &block|
        unless candidate == path
          next original.call(
            candidate, *args, **kwargs, &block
          )
        end

        source = original.call(candidate, *args, **kwargs)
        proxy = Object.new
        proxy.define_singleton_method(:stat) { File.stat(other) }
        proxy.define_singleton_method(:read) do |limit|
          source.read(limit)
        end
        begin
          block.call(proxy)
        ensure
          source.close
        end
      end
      with_replaced_singleton_method(
        File, :open, replacement
      ) do
        assert_raises(Hive::ConfigError) do
          journal.fetch(patrol_capture.occurrence_id)
        end
      end
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      FileUtils.mkdir_p(journal.root)
      target = File.join(root, "target")
      File.write(target, "{}")
      symlink = File.join(
        journal.root, "#{patrol_capture.occurrence_id}.json"
      )
      File.symlink(target, symlink)
      assert_raises(Hive::ConfigError) do
        journal.fetch(patrol_capture.occurrence_id)
      end
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      File.write(journal.root, "not-a-directory")
      assert_raises(Hive::ConfigError) { journal.each_record.count }
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      journal.reserve!(patrol_capture, now: NOW)
      journal.reserve!(
        patrol_capture(
          trigger: { "kind" => "manual", "id" => "second" }
        ),
        now: NOW
      )
      with_constant(
        Hive::Modules::Migration::OccurrenceRecordStore,
        :MAX_HISTORY_RECORDS,
        1
      ) do
        assert_raises(Hive::ConfigError) { journal.each_record.count }
      end
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      FileUtils.mkdir_p(journal.root)
      original = File.method(:lstat)
      replacement = lambda do |path|
        raise Errno::EACCES, path if path == journal.root

        original.call(path)
      end
      with_replaced_singleton_method(
        File, :lstat, replacement
      ) do
        assert_raises(Hive::ConfigError) { journal.each_record.count }
      end
    end
  end

  def test_mutation_io_size_and_outbox_conflict_guards
    with_journal do |journal|
      record = mutable(journal.fetch(patrol_capture.occurrence_id))
      outbox = Hive::Modules::Migration::OccurrenceOutbox.new(
        validator: occurrence_validator
      )
      assert_raises(Hive::ConfigError) do
        outbox.append(
          record,
          kind: "unknown",
          id: "id",
          bytes: canonical({})
        )
      end

      first = outbox.append(
        record,
        kind: "event",
        id: "evt-#{'a' * 64}",
        bytes: canonical("event_id" => "evt-#{'a' * 64}")
      )
      assert_same first, outbox.append(
        record,
        kind: "event",
        id: "evt-#{'a' * 64}",
        bytes: canonical("event_id" => "evt-#{'a' * 64}")
      )
      assert_raises(Hive::ConfigError) do
        outbox.append(
          record,
          kind: "event",
          id: "evt-#{'a' * 64}",
          bytes: canonical(
            "event_id" => "evt-#{'a' * 64}",
            "changed" => true
          )
        )
      end

      bounded = mutable(journal.fetch(patrol_capture.occurrence_id))
      bounded["outbox"] = Array.new(
        Hive::Modules::Migration::OccurrenceContract::
          MAX_OUTBOX_ENTRIES
      ) do |index|
        {
          "kind" => "event",
          "id" => "existing-#{index}"
        }
      end
      assert_raises(Hive::ConfigError) do
        outbox.append(
          bounded,
          kind: "event",
          id: "evt-#{'b' * 64}",
          bytes: canonical("event_id" => "evt-#{'b' * 64}")
        )
      end

      missing = patrol_capture(
        trigger: { "kind" => "manual", "id" => "missing" }
      )
      store = Hive::Modules::Migration::OccurrenceRecordStore.new(
        root: journal.root,
        validator: occurrence_validator
      )
      assert_raises(Hive::ConfigError) do
        store.mutate(missing.occurrence_id) { |value| value }
      end

      record_store = journal.instance_variable_get(:@store)
      directory = record_store.instance_variable_get(:@directory)
      writes = 0
      original = directory.method(:atomic_write)
      directory.define_singleton_method(:atomic_write) do |*args, **kwargs|
        writes += 1
        original.call(*args, **kwargs)
      end
      journal.reserve!(patrol_capture, now: NOW)
      assert_equal 0, writes,
                   "byte-identical replay must not rewrite and fsync"

      directory.define_singleton_method(:atomic_write) do |*args, **_kwargs|
        raise Errno::ENOSPC, args.fetch(0)
      end
      assert_raises(Hive::ConfigError) do
        journal.reserve!(missing, now: NOW)
      end
    end

    with_tmp_dir do |root|
      validator = Object.new
      validator.define_singleton_method(:occurrence_id) do |value|
        value
      end
      validator.define_singleton_method(:copy) do |value|
        value
      end
      validator.define_singleton_method(:validate!) do |_record, expected_id:|
        expected_id
      end
      validator.define_singleton_method(:canonical) do |_record|
        "x" * (
          Hive::Modules::Migration::OccurrenceContract::
            MAX_RECORD_BYTES + 1
        )
      end
      store = Hive::Modules::Migration::OccurrenceRecordStore.new(
        root: File.join(root, "occurrences"),
        validator: validator
      )
      occurrence_id = "occ-#{'0' * 64}"
      assert_raises(Hive::ConfigError) do
        store.mutate(occurrence_id, create: true) { {} }
      end
    end
  end

  def test_effect_and_outbox_limits_are_enforced_before_growth
    with_journal do |journal|
      with_constant(
        Hive::Modules::Migration::PatrolEvidence,
        :MAX_EFFECTS_PER_OCCURRENCE,
        0
      ) do
        assert_raises(Hive::ConfigError) do
          journal.prepare_effect!(effect_intent, now: NOW)
        end
      end
    end
  end

  def test_collaborator_corruption_guards_reject_unvalidated_recovery_state
    with_journal do |journal|
      capture = patrol_capture
      record = mutable(journal.fetch(capture.occurrence_id))

      wrong_module = mutable(record)
      wrong_module["module"] = "architecture-patrol"
      assert_raises(Hive::ConfigError) do
        journal.send(
          :validate_occurrence_identity!, wrong_module, capture
        )
      end

      other = patrol_capture(
        trigger: { "kind" => "manual", "id" => "other" }
      )
      wrong_provisional = mutable(record)
      wrong_provisional["provisional_capture"] = other.to_h
      assert_raises(Hive::ConfigError) do
        journal.send(
          :validate_occurrence_identity!, wrong_provisional, capture
        )
      end

      missing_identity = mutable(record)
      missing_identity.delete("module")
      assert_raises(Hive::ConfigError) do
        journal.send(
          :validate_occurrence_identity!, missing_identity, capture
        )
      end

      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      effects = journal.instance_variable_get(:@effects)
      cell = mutable(journal.effect_state(intent))
      assert_raises(Hive::ConfigError) do
        effects.send(:effect_cell!, { "effects" => {} }, intent)
      end

      conflicting = mutable(cell)
      conflicting.fetch("semantic")["target"] = "other"
      assert_raises(Hive::ConfigError) do
        effects.send(
          :validate_effect_identity!, conflicting, intent
        )
      end

      malformed = mutable(cell)
      malformed.delete("intent_id")
      assert_raises(Hive::ConfigError) do
        effects.send(:validate_effect_identity!, malformed, intent)
      end
    end
  end

  def test_validator_and_outbox_reject_foreign_or_noncanonical_payloads
    validator = occurrence_validator
    foreign_capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "candidate",
        "job_id" => "job-1",
        "phase" => "discovery"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "architecture-patrol",
          rationale: "due",
          job_id: "job-1",
          phase: "discovery"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )
    assert_raises(Hive::ConfigError) do
      validator.capture(foreign_capture)
    end

    foreign_intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "architecture-patrol",
      occurrence_id: "occ-#{'a' * 64}",
      authority: "legacy",
      owner_epoch: 1,
      sink: "state",
      target: "state",
      idempotency_key: "state",
      capability: "filesystem_write",
      created_at: NOW
    )
    assert_raises(Hive::ConfigError) do
      validator.intent(foreign_intent)
    end
    assert_raises(Hive::ConfigError) do
      validator.canonical_bytes(
        JSON.pretty_generate("event_id" => "evt-#{'a' * 64}"),
        "event"
      )
    end
    assert_raises(Hive::ConfigError) do
      validator.send(
        :validate_outbox_value,
        "unknown",
        "id",
        canonical({}),
        occurrence_id: patrol_capture.occurrence_id
      )
    end
    assert_raises(Hive::ConfigError) do
      validator.send(
        :validate_outbox_value,
        "event",
        "id",
        "{bad",
        occurrence_id: patrol_capture.occurrence_id
      )
    end

    outbox = Hive::Modules::Migration::OccurrenceOutbox.new(
      validator: validator
    )
    receipt_id = "receipt-#{'a' * 64}"
    corrupt_record = {
      "outbox" => [
        {
          "kind" => "receipt",
          "id" => receipt_id,
          "bytes" => "{bad"
        }
      ]
    }
    assert_raises(Hive::ConfigError) do
      outbox.receipt(corrupt_record, receipt_id)
    end
  end

  def test_record_store_detects_growth_between_stat_and_read
    with_tmp_dir do |root|
      occurrence_id = patrol_capture.occurrence_id
      path = File.join(root, "#{occurrence_id}.json")
      File.write(path, "{}")
      initial = File.lstat(path)
      oversized = "x" * (
        Hive::Modules::Migration::OccurrenceContract::MAX_RECORD_BYTES + 1
      )
      proxy = Object.new
      proxy.define_singleton_method(:stat) { initial }
      proxy.define_singleton_method(:read) { |_limit| oversized }

      original = File.method(:open)
      replacement = lambda do |candidate, *args, **kwargs, &block|
        unless candidate == path
          next original.call(
            candidate, *args, **kwargs, &block
          )
        end

        block.call(proxy)
      end
      store = Hive::Modules::Migration::OccurrenceRecordStore.new(
        root: root,
        validator: occurrence_validator
      )
      with_replaced_singleton_method(
        File, :open, replacement
      ) do
        assert_raises(Hive::ConfigError) do
          store.fetch(occurrence_id)
        end
      end
    end
  end

  private

  def occurrence_journal(root)
    Hive::Modules::Migration::OccurrenceJournal.new(
      root, module_name: "patrol"
    )
  end

  def schedule_capture(base, window:, generation:)
    patrol_capture(
      trigger: {
        "kind" => "schedule",
        "id" => "#{base}:attempt:#{generation}"
      },
      reservation: {
        "kind" => "ordinary",
        "id" => base,
        "window_started_at" => window.iso8601(6),
        "attempt_generation" => generation
      }
    )
  end

  def architecture_capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "pull_request.merged", "id" => "merge-1" },
      reservation: {
        "kind" => "architecture",
        "id" => "job-1",
        "job_id" => "job-1"
      },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "candidate",
        "job_id" => "job-1",
        "phase" => "discovery"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "architecture-patrol",
          rationale: "due",
          job_id: "job-1",
          phase: "discovery"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: NOW,
      recorded_at: NOW
    )
  end

  def acknowledge_all(journal, occurrence_id)
    journal.pending_outbox(occurrence_id).each do |entry|
      journal.acknowledge_outbox!(
        occurrence_id,
        entry_id: entry.fetch("id"),
        digest: entry.fetch("digest")
      )
    end
  end

  def trace_journal_locks(journal, events:, stack:)
    locks = [
      [ journal, :@attempt_locks, :identity ],
      [
        journal.instance_variable_get(:@journal_state),
        :@lock,
        :journal_state
      ],
      [ journal, :@inventory_lock, :inventory ],
      [
        journal.instance_variable_get(:@store),
        :@record_locks,
        :record
      ]
    ]
    locks.each do |owner, variable, label|
      delegate = owner.instance_variable_get(variable)
      wrapper = Object.new
      wrapper.define_singleton_method(:synchronize) do |name, &block|
        delegate.synchronize(name) do
          events << { event: :enter, lock: label, held: stack.dup }
          stack << label
          begin
            block.call
          ensure
            stack.pop
            events << { event: :exit, lock: label, held: stack.dup }
          end
        end
      end
      owner.instance_variable_set(variable, wrapper)
    end
  end

  def invalidating_record(record)
    active = true
    proxy = Object.new
    check = lambda do
      raise "single-pass record was retained" unless active
    end
    proxy.define_singleton_method(:fetch) do |*arguments, &block|
      check.call
      record.fetch(*arguments, &block)
    end
    proxy.define_singleton_method(:dig) do |*arguments|
      check.call
      record.dig(*arguments)
    end
    proxy.define_singleton_method(:invalidate!) { active = false }
    proxy
  end

  def with_journal
    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      journal.reserve!(patrol_capture, now: NOW)
      yield journal
    end
  end

  def patrol_capture(outcome_class: nil,
                     outcome: nil,
                     effect_ids: [],
                     trigger: { "kind" => "manual", "id" => "manual-1" },
                     reservation: {
                       "kind" => "ordinary", "id" => "reservation-1"
                     })
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation: reservation,
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: outcome_class,
      outcome: outcome,
      effect_ids: effect_ids,
      occurred_at: NOW,
      recorded_at: NOW
    )
  end

  def terminal_capture(capture, outcome_class: "completed",
                       outcome: { "rationale" => "completed" })
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: capture.module_name,
      project: capture.project,
      trigger: capture.trigger,
      reservation: capture.reservation,
      owner: capture.owner,
      owner_epoch: capture.owner_epoch,
      selection_input: capture.selection_input,
      selection: capture.selection,
      outcome_class: outcome_class,
      outcome: outcome,
      effect_ids: capture.effect_ids,
      occurred_at: capture.occurred_at,
      recorded_at: NOW + 1
    )
  end

  def effect_intent(target: "owner/demo:branch",
                    capability: "github_pull_requests")
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: patrol_capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "pull_request",
      target: target,
      idempotency_key: "finding-1:pull-request:#{target}",
      capability: capability,
      scope: { "fingerprint" => "fingerprint-1" },
      created_at: NOW
    )
  end

  def receipt(intent, status, outcome)
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: status,
      outcome: outcome,
      recorded_at: NOW
    )
  end

  def occurrence_validator
    Hive::Modules::Migration::OccurrenceRecordValidator.new(
      module_name: "patrol"
    )
  end

  def assert_invalid_record(validator, record)
    assert_raises(Hive::ConfigError) do
      validator.validate!(
        record,
        expected_id: patrol_capture.occurrence_id
      )
    end
  end

  def outbox_entry(sequence:, kind:, id:, bytes:)
    {
      "sequence" => sequence,
      "kind" => kind,
      "id" => id,
      "digest" => Digest::SHA256.hexdigest(bytes),
      "bytes" => bytes,
      "acknowledged" => false
    }
  end

  def mutable(value)
    JSON.parse(JSON.generate(value))
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def with_constant(owner, name, replacement)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end
end
