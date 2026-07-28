require "test_helper"
require "hive/modules/migration/occurrence_journal"

class ModulesMigrationOccurrenceJournalTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_sender_lease_recovery_and_terminal_replay_contract
    with_journal do |journal|
      first = effect_intent
      alternate = effect_intent(capability: "github_pull_requests:alternate")
      journal.prepare_effect!(first, now: NOW)
      journal.prepare_effect!(alternate, now: NOW)
      assert_equal [ first.occurrence_id ],
                   journal.pending.map { |record| record.fetch("occurrence_id") }
      assert_equal 1, journal.records.size
      assert_empty journal.projection_pending
      journal.reserve!(patrol_capture, now: NOW)

      claim = journal.acquire_effect!(
        first, claimant: "sender-one", now: NOW, lease_sec: 10
      )
      assert_equal :acquired, claim.status
      busy = journal.acquire_effect!(
        first, claimant: "sender-two", now: NOW + 1, lease_sec: 10
      )
      assert_equal :busy, busy.status
      expired = journal.acquire_effect!(
        first, claimant: "sender-two", now: NOW + 11, lease_sec: 10
      )
      assert_equal :reconcile, expired.status
      assert_equal "dispatch_uncertain", expired.delivery_state

      assert_raises(Hive::ConfigError) do
        journal.acquire_effect!(
          first, claimant: "sender-two", now: nil, lease_sec: 10
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.mark_dispatch_uncertain!(
          first, token: claim.token, now: NOW + 12
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.resolve_absent!(
          first,
          expected_generation: "bad",
          outcome: {},
          receipt: receipt(first, "known_not_sent", {}),
          now: NOW + 12
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.resolve_absent!(
          first,
          expected_generation: claim.generation + 1,
          outcome: {},
          receipt: receipt(first, "known_not_sent", {}),
          now: NOW + 12
        )
      end

      absent_outcome = { "remote" => "absent" }
      absent_receipt = receipt(
        first, "known_not_sent", absent_outcome
      )
      journal.resolve_absent!(
        first,
        expected_generation: claim.generation,
        outcome: absent_outcome,
        receipt: absent_receipt,
        now: NOW + 12
      )
      fresh = journal.acquire_effect!(
        first, claimant: "sender-two", now: NOW + 13, lease_sec: 10
      )
      journal.mark_dispatch_uncertain!(
        first, token: fresh.token, now: NOW + 13
      )
      outcome = { "url" => "https://example.test/effect/1" }
      committed = receipt(first, "committed", outcome)
      journal.settle_claimed!(
        first,
        token: fresh.token,
        status: "committed",
        outcome: outcome,
        receipt: committed,
        now: NOW + 14
      )

      terminal = journal.acquire_effect!(
        first, claimant: "sender-three", now: NOW + 15
      )
      assert_equal :terminal, terminal.status
      assert_equal committed.receipt_id, terminal.receipt
      assert_equal committed.to_h, journal.receipt(
        committed.receipt_id, occurrence_id: first.occurrence_id
      ).to_h
      assert_equal [ committed.receipt_id ],
                   journal.effect_receipt_ids(first.occurrence_id)
      assert_equal(
        [ absent_receipt.receipt_id, committed.receipt_id ].sort,
        journal.effect_state(first).fetch("receipt_ids").sort
      )
    end
  end

  def test_settlement_and_denial_conflicts_fail_closed
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)

      assert_raises(Hive::ConfigError) do
        journal.settle_claimed!(
          intent,
          token: "missing",
          status: "unknown",
          outcome: {},
          receipt: receipt(intent, "failed", {}),
          now: NOW
        )
      end

      claim = journal.acquire_effect!(
        intent, claimant: "sender", now: NOW, lease_sec: 30
      )
      assert_raises(Hive::ConfigError) do
        journal.settle_claimed!(
          intent,
          token: claim.token,
          status: "committed",
          outcome: {},
          receipt: receipt(intent, "committed", {}),
          now: NOW
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.mark_dispatch_uncertain!(
          intent, token: "stale", now: NOW
        )
      end

      journal.mark_dispatch_uncertain!(
        intent, token: claim.token, now: NOW
      )
      denial = receipt(intent, "denied", { "reason" => "revoked" })
      journal.deny_prepared!(
        intent,
        outcome: denial.outcome,
        receipt: denial,
        now: NOW
      )
      assert_equal "dispatch_uncertain",
                   journal.effect_state(intent).fetch("state")
      assert_includes journal.effect_state(intent).fetch("receipt_ids"),
                      denial.receipt_id

      assert_raises(Hive::ConfigError) do
        journal.settle_claimed!(
          intent,
          token: claim.token,
          status: "committed",
          outcome: {},
          receipt: receipt(intent, "denied", {}),
          now: NOW
        )
      end
      outcome = { "url" => "https://example.test/effect/1" }
      committed = receipt(intent, "committed", outcome)
      journal.settle_claimed!(
        intent,
        token: claim.token,
        status: "committed",
        outcome: outcome,
        receipt: committed,
        now: NOW
      )
      journal.deny_prepared!(
        intent,
        outcome: { "reason" => "late" },
        receipt: receipt(intent, "denied", { "reason" => "late" }),
        now: NOW
      )
      assert_equal "committed",
                   journal.effect_state(intent).fetch("state")
    end
  end

  def test_reconciled_settlement_is_idempotent_but_not_rewritable
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      claim = journal.acquire_effect!(
        intent, claimant: "sender", now: NOW, lease_sec: 1
      )
      journal.mark_dispatch_uncertain!(
        intent, token: claim.token, now: NOW
      )
      outcome = { "remote" => "matched" }
      reconciled = receipt(intent, "reconciled", outcome)
      assert_raises(Hive::ConfigError) do
        journal.settle_reconciled!(
          intent,
          expected_generation: claim.generation + 1,
          outcome: outcome,
          receipt: reconciled,
          now: NOW + 1
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.settle_reconciled!(
          intent,
          expected_generation: "bad",
          outcome: outcome,
          receipt: reconciled,
          now: NOW + 1
        )
      end
      journal.settle_reconciled!(
        intent,
        expected_generation: claim.generation,
        outcome: outcome,
        receipt: reconciled,
        now: NOW + 2
      )
      journal.settle_reconciled!(
        intent,
        expected_generation: claim.generation,
        outcome: outcome,
        receipt: reconciled,
        now: NOW + 3
      )

      assert_raises(Hive::ConfigError) do
        journal.settle_reconciled!(
          intent,
          expected_generation: claim.generation,
          outcome: { "remote" => "different" },
          receipt: receipt(
            intent, "reconciled", { "remote" => "different" }
          ),
          now: NOW + 4
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.settle_reconciled!(
          effect_intent(target: "other"),
          expected_generation: "bad",
          outcome: {},
          receipt: receipt(
            effect_intent(target: "other"), "reconciled", {}
          ),
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
      claim = journal.acquire_effect!(
        intent, claimant: "sender", now: NOW
      )
      journal.mark_dispatch_uncertain!(
        intent, token: claim.token, now: NOW
      )
      outcome = { "url" => "https://example.test/effect/1" }
      committed = receipt(intent, "committed", outcome)
      journal.settle_claimed!(
        intent,
        token: claim.token,
        status: "committed",
        outcome: outcome,
        receipt: committed,
        now: NOW
      )
      final = patrol_capture(
        decision_class: "completed",
        decision: { "rationale" => "completed" },
        effect_ids: [ committed.receipt_id ]
      )
      event = canonical(
        "event_id" => "evt-#{'a' * 64}",
        "payload" => { "capture" => final.to_h }
      )

      missing_effect = patrol_capture(
        decision_class: "completed",
        decision: { "rationale" => "completed" },
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
      pending_ids = journal.projection_pending.map do |record|
        record.fetch("occurrence_id")
      end
      assert_equal [ final.occurrence_id ], pending_ids
      assert_equal %w[capture event receipt],
                   replay.fetch("outbox").map { |entry| entry.fetch("kind") }
                         .sort

      conflicting = patrol_capture(
        decision_class: "failed",
        decision: { "rationale" => "failed" },
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

  def test_outbox_acknowledgement_and_receipt_reads_reject_tampering
    with_journal do |journal|
      intent = effect_intent
      journal.prepare_effect!(intent, now: NOW)
      outcome = { "reason" => "revoked" }
      denied = receipt(intent, "denied", outcome)
      journal.deny_prepared!(
        intent, outcome: outcome, receipt: denied, now: NOW
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
        journal.acquire_effect!(
          intent, claimant: "", now: NOW, lease_sec: 1
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.acquire_effect!(
          intent, claimant: "sender", now: NOW, lease_sec: 0
        )
      end
      assert_raises(Hive::ConfigError) do
        journal.acquire_effect!(
          intent, claimant: "sender", now: NOW, lease_sec: "bad"
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

      leased = journal.acquire_effect!(
        prepared_intent, claimant: "sender", now: NOW, lease_sec: 10
      )
      invalid_claim = mutable(journal.fetch(prepared_intent.occurrence_id))
      invalid_claim.dig(
        "effects", prepared_intent.intent_id, "claim"
      )["generation"] = leased.generation + 1
      assert_invalid_record(validator, invalid_claim)

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
      assert_raises(Hive::ConfigError) { journal.records }
    end

    with_tmp_dir do |root|
      journal = Hive::Modules::Migration::OccurrenceJournal.new(
        File.join(root, "occurrences"),
        module_name: "patrol"
      )
      FileUtils.mkdir_p(journal.root)
      original = Dir.method(:each_child)
      replacement = lambda do |path, &block|
        if path == journal.root
          4_097.times do |index|
            block.call("occ-#{format('%064x', index)}.json")
          end
        else
          original.call(path, &block)
        end
      end
      with_replaced_singleton_method(
        Dir, :each_child, replacement
      ) do
        assert_raises(Hive::ConfigError) { journal.records }
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
        assert_raises(Hive::ConfigError) { journal.records }
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

      original = Hive::AtomicFile.method(:write)
      replacement = lambda do |*args, **kwargs|
        if args.fetch(0).start_with?(journal.root)
          raise Errno::ENOSPC, args.fetch(0)
        end
        original.call(*args, **kwargs)
      end
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, replacement
      ) do
        assert_raises(Hive::ConfigError) do
          journal.reserve!(missing, now: NOW)
        end
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
        effects.send(:existing_claim_disposition, cell, now: NOW)
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
      decision_class: "due",
      decision: {},
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
      path = File.join(root, "occurrence.json")
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
          store.send(:bounded_regular_read, path)
        end
      end
    end
  end

  private

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

  def patrol_capture(decision_class: "due",
                     decision: { "rationale" => "due" },
                     effect_ids: [],
                     trigger: { "kind" => "manual", "id" => "manual-1" })
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: decision_class,
      decision: decision,
      effect_ids: effect_ids,
      occurred_at: NOW,
      recorded_at: NOW
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
