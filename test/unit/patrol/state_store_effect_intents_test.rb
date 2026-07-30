require "test_helper"
require "timeout"
require "hive/modules/migration/evidence_store"
require "hive/patrol/state_store"

class PatrolStateStoreEffectIntentsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_cycle_lock_is_reentrant_and_serializes_store_instances
    with_tmp_dir do |root|
      first = Hive::Patrol::StateStore.new(root)
      second = Hive::Patrol::StateStore.new(root)
      entered = Queue.new
      release = Queue.new
      successor = Queue.new
      first_thread = Thread.new do
        first.with_cycle_lock do
          first.with_cycle_lock { entered << true }
          release.pop
        end
      end
      entered.pop
      second_thread = Thread.new do
        second.with_cycle_lock { successor << true }
      end

      assert_raises(Timeout::Error) do
        Timeout.timeout(0.1) { successor.pop }
      end
      release << true
      assert Timeout.timeout(2) { successor.pop }
      first_thread.join
      second_thread.join
    ensure
      release << true if first_thread&.alive?
      first_thread&.join
      second_thread&.join
    end
  end

  def test_occurrence_journal_is_the_only_effect_recovery_authority
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)

      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      outcome = publication_outcome
      receipt = store.settle_effect!(
        intent, status: "committed", outcome: outcome, now: NOW
      )

      reloaded = Hive::Patrol::StateStore.new(root)
      assert_equal "committed", reloaded.effect_state(intent).fetch("state")
      assert_equal receipt.to_h, reloaded.effect_receipt(
        receipt.receipt_id, occurrence_id: intent.occurrence_id
      ).to_h
      assert_equal %w[publication receipt],
                   reloaded.send(
                     :instance_variable_get, :@occurrence_store
                   ).pending_outbox(intent.occurrence_id).map {
                     |entry| entry.fetch("kind")
                   }.sort
      refute reloaded.state.key?("effect_intents")
      assert reloaded.fingerprints.values.none? do |entry|
        entry.is_a?(Hash) && entry.key?("effect_intents")
      end
    end
  end

  def test_publication_projection_survives_ack_crash_and_replays_as_noop
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      receipt = store.settle_effect!(
        intent,
        status: "committed",
        outcome: publication_outcome,
        now: NOW
      )
      occurrence_store =
        store.instance_variable_get(:@occurrence_store)
      original_ack = occurrence_store.method(:acknowledge_outbox!)
      occurrence_store.define_singleton_method(
        :acknowledge_outbox!
      ) do |occurrence_id, **options|
        if options.fetch(:kind) == "publication"
          raise IOError, "crash before publication acknowledgement"
        end
        original_ack.call(occurrence_id, **options)
      end

      assert_raises(IOError) do
        store.drain_publication_outbox!(intent.occurrence_id)
      end
      projected = store.fingerprints.fetch("fingerprint-1")
      binding = projected.fetch("publication_binding")
      assert_equal receipt.receipt_id, binding.fetch("receipt_id")
      assert_equal "reconciliation_pending",
                   projected.fetch("state")
      assert_equal %w[shared title],
                   projected.fetch("title_tokens")

      reloaded = Hive::Patrol::StateStore.new(root)
      writes = 0
      original_write =
        reloaded.method(:raw_write_fingerprints)
      reloaded.define_singleton_method(
        :raw_write_fingerprints
      ) do |data|
        writes += 1
        original_write.call(data)
      end
      reloaded.drain_publication_outbox!(intent.occurrence_id)

      assert_equal 0, writes
      assert_equal projected,
                   reloaded.fingerprints.fetch("fingerprint-1")
      assert_equal [ "receipt" ],
                   reloaded.instance_variable_get(:@occurrence_store)
                           .pending_outbox(intent.occurrence_id)
                           .map { |entry| entry.fetch("kind") }
    end
  end

  def test_publication_projection_rejects_an_immutable_binding_conflict
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      receipt = store.settle_effect!(
        intent,
        status: "committed",
        outcome: publication_outcome,
        now: NOW
      )
      binding =
        store.send(:publication_binding_from, receipt).fetch(0)
      conflicting = JSON.parse(JSON.generate(binding))
      conflicting["pr_url"] =
        "https://github.com/owner/demo/pull/99"
      store.send(:with_fingerprint_lock) do
        store.send(
          :raw_write_fingerprints,
          "fingerprint-1" => {
            "publication_binding" => conflicting
          }
        )
      end

      error = assert_raises(Hive::ConfigError) do
        store.drain_publication_outbox!(intent.occurrence_id)
      end

      assert_equal "patrol publication binding conflicts",
                   error.message
      assert_equal conflicting,
                   store.fingerprints.dig(
                     "fingerprint-1", "publication_binding"
                   )
      assert_includes(
        store.instance_variable_get(:@occurrence_store)
             .pending_outbox(intent.occurrence_id)
             .map { |entry| entry.fetch("kind") },
        "publication"
      )
    end
  end

  def test_generic_recovery_drain_projects_publication_and_receipt
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      receipt = store.settle_effect!(
        intent,
        status: "reconciled",
        outcome: publication_outcome,
        now: NOW
      )
      evidence =
        Hive::Modules::Migration::EvidenceStore.new(
          root: File.join(root, "evidence")
        )

      store.drain_occurrence_outbox!(
        intent.occurrence_id,
        evidence_store: evidence
      )

      assert_equal [ receipt.receipt_id ],
                   evidence.receipts.map(&:receipt_id)
      assert_equal receipt.receipt_id,
                   store.fingerprints.dig(
                     "fingerprint-1",
                     "publication_binding",
                     "receipt_id"
                   )
      assert_empty(
        store.instance_variable_get(:@occurrence_store)
             .pending_outbox(intent.occurrence_id)
      )
    end
  end

  def test_legacy_parallel_effect_maps_and_methods_are_absent
    source = File.read(
      File.expand_path(
        "../../../lib/hive/patrol/state_store.rb", __dir__
      )
    )

    %w[
      reserve_effect_intent effect_intent_state record_effect_outcome
      reserve_cycle_effect_intent cycle_effect_intent_state
      record_cycle_effect_outcome
    ].each do |legacy_method|
      refute_includes source, "def #{legacy_method}"
      refute Hive::Patrol::StateStore.public_instance_methods(false)
        .include?(legacy_method.to_sym)
      refute Hive::Patrol::StateStore.private_instance_methods(false)
        .include?(legacy_method.to_sym)
    end
  end

  def test_occurrence_enumeration_preserves_the_journal_recovery_views
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.reserve_occurrence!(capture, now: NOW)
      finalized = Hive::Modules::Migration::PatrolCapture.build(
        module_name: capture.module_name, project: capture.project,
        trigger: capture.trigger, reservation: capture.reservation,
        owner: capture.owner, owner_epoch: capture.owner_epoch,
        selection_input: capture.selection_input, selection: capture.selection,
        outcome_class: "completed", outcome: { "rationale" => "completed" },
        occurred_at: capture.occurred_at, recorded_at: NOW + 1
      )
      unavailable_evidence = Object.new
      unavailable_evidence.define_singleton_method(:append_capture) do |_capture|
        raise IOError, "comparison projection unavailable"
      end
      assert_raises(IOError) do
        store.finalize_occurrence!(
          capture: finalized, evidence_store: unavailable_evidence, now: NOW + 1
        )
      end

      reserved = []
      projection_pending = []
      all = []
      store.each_reserved_occurrence { |record| reserved << record.fetch("occurrence_id") }
      store.each_projection_pending_occurrence do |record|
        projection_pending << record.fetch("occurrence_id")
      end
      store.each_occurrence { |record| all << record.fetch("occurrence_id") }

      assert_empty reserved
      assert_equal [ capture.occurrence_id ], projection_pending
      assert_equal [ capture.occurrence_id ], all
      assert_equal reserved,
                   store.each_reserved_occurrence.map { |record| record.fetch("occurrence_id") }
      assert_equal projection_pending,
                   store.each_projection_pending_occurrence.map { |record| record.fetch("occurrence_id") }
      assert_equal all, store.each_occurrence.map { |record| record.fetch("occurrence_id") }
      assert_equal(
        [ capture.occurrence_id ],
        store.rebuild_recovery_index!.fetch("occurrence_ids")
      )
    end
  end

  def test_terminal_effect_requires_its_exact_canonical_outbox_receipt
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      outcome = publication_outcome
      store.settle_effect!(
        intent, status: "committed", outcome: outcome, now: NOW
      )
      path = File.join(
        store.root, "occurrences", "#{capture.occurrence_id}.json"
      )
      record = JSON.parse(File.read(path))
      record.dig("effects", intent.intent_id)["terminal_receipt_id"] = nil
      File.write(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(record)
      )

      error = assert_raises(Hive::ConfigError) do
        Hive::Patrol::StateStore.new(root).occurrence(capture.occurrence_id)
      end
      assert_equal "patrol effect terminal receipt is malformed",
                   error.message
    end
  end

  def test_configured_store_routes_state_finding_and_attempt_writes_through_gateway
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "evidence")
      )
      store.configure_effect_gateway!(
        capture: capture,
        evidence_store: evidence,
        config_loader: ->(_path) { { "patrol" => { "enabled" => true } } },
        capability_checker: ->(**) { true }
      )
      finding = Struct.new(:id) do
        def to_h = { "id" => id, "title" => "Finding" }
      end.new("finding-1")
      patch = {
        "id" => "patch-1",
        "fingerprint" => "fingerprint-1",
        "passed" => true
      }

      store.update_state("last_run_at" => NOW.iso8601)
      store.write_fingerprints("fingerprint-1" => { "state" => "open" })
      store.write_finding(finding)
      perform_attempt(store, patch)
      receipt_count = evidence.receipts.size

      store.update_state("last_run_at" => NOW.iso8601)
      store.write_fingerprints("fingerprint-1" => { "state" => "open" })
      store.write_finding(finding)
      perform_attempt(store, patch)

      assert_equal receipt_count, evidence.receipts.size
      assert_equal %w[attempt finding state],
                   evidence.receipts.map { |receipt| receipt.intent.sink }.uniq.sort
      assert_equal %w[committed], evidence.receipts.map(&:status).uniq.sort
      assert_equal NOW.iso8601, store.state.fetch("last_run_at")
      assert_equal patch, store.read_json(
        File.join(store.root, "patches", "patch-1.json")
      ).except("patrol_occurrence_id")
    end
  end

  def test_fingerprint_recovery_normalizes_malformed_enumeration
    with_tmp_dir do |root|
      store = configured_store(root, File.join(root, "evidence"))
      store.define_singleton_method(
        :each_recovery_active_occurrence
      ) do
        raise JSON::ParserError, "malformed recovery index"
      end

      error = assert_raises(Hive::ConfigError) do
        store.recover_pending_fingerprint_effects!
      end

      assert_equal(
        "patrol fingerprint recovery operation is malformed",
        error.message
      )
    end
  end

  def test_fingerprint_recovery_rejects_foreign_predecessors
    with_tmp_dir do |root|
      store = configured_store(root, File.join(root, "evidence"))
      foreign = capture(
        identity: "foreign",
        project: {
          "project_id" => "project-2",
          "name" => "foreign",
          "repository" => "owner/foreign"
        }
      )
      store.define_singleton_method(
        :each_recovery_active_occurrence
      ) do |&block|
        block.call(
          "provisional_capture" => foreign.to_h,
          "effects" => {}
        )
      end

      error = assert_raises(Hive::ConfigError) do
        store.recover_pending_fingerprint_effects!
      end

      assert_match(/recovery project is malformed/, error.message)
    end
  end

  def test_fingerprint_recovery_rejects_competing_and_malformed_operations
    with_tmp_dir do |root|
      store = configured_store(root, File.join(root, "evidence"))
      first = capture(identity: "first")
      second = capture(identity: "second", at: NOW + 1)
      [ first, second ].each do |predecessor|
        store.reserve_occurrence!(predecessor, now: NOW)
        store.prepare_effect!(
          fingerprint_intent(
            predecessor,
            idempotency_key: predecessor.reservation.fetch("id"),
            deleted: []
          ),
          now: NOW
        )
      end

      duplicate = assert_raises(Hive::ConfigError) do
        store.recover_pending_fingerprint_effects!
      end
      assert_match(/multiple nonterminal fingerprint effects/,
                   duplicate.message)
    end

    with_tmp_dir do |root|
      store = configured_store(root, File.join(root, "evidence"))
      predecessor = capture(identity: "malformed")
      store.reserve_occurrence!(predecessor, now: NOW)
      store.prepare_effect!(
        fingerprint_intent(
          predecessor,
          idempotency_key: "malformed",
          deleted: [ 7 ]
        ),
        now: NOW
      )

      malformed = assert_raises(Hive::ConfigError) do
        store.recover_pending_fingerprint_effects!
      end
      assert_equal(
        "patrol fingerprint recovery operation is malformed",
        malformed.message
      )
    end
  end

  def test_outbox_rejects_unpublishable_events_unknown_kinds_and_invalid_json
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      evidence = Object.new
      occurrence_store = Object.new
      pending = []
      occurrence_store.define_singleton_method(:pending_outbox) { |_occurrence_id| pending }
      occurrence_store.define_singleton_method(:acknowledge_outbox!) do |*|
        raise "invalid outbox entries must never be acknowledged"
      end
      store.instance_variable_set(:@occurrence_store, occurrence_store)

      pending.replace([ outbox_entry("event", "{}") ])
      unavailable = assert_raises(Hive::ConfigError) do
        store.drain_occurrence_outbox!("occurrence-1", evidence_store: evidence)
      end
      pending.replace([ outbox_entry("unknown", "{}") ])
      unknown = assert_raises(Hive::ConfigError) do
        store.drain_occurrence_outbox!("occurrence-1", evidence_store: evidence)
      end
      pending.replace([ outbox_entry("capture", "{") ])
      malformed = assert_raises(Hive::ConfigError) do
        store.drain_occurrence_outbox!("occurrence-1", evidence_store: evidence)
      end

      assert_equal "patrol finalized event publisher is unavailable", unavailable.message
      assert_equal "patrol outbox kind is malformed", unknown.message
      assert_equal "patrol outbox bytes are malformed", malformed.message
    end
  end

  def test_retry_safe_absence_resets_only_to_prepared
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)
      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      store.reset_effect_prepared!(intent, now: NOW + 1)

      state = store.effect_state(intent)
      assert_equal "prepared", state.fetch("state")
      assert_empty state.fetch("receipt_ids")
      refute_includes state, "claim"
      refute_includes state, "delivery_generation"
    end
  end

  def test_gateway_denials_are_normalized_at_both_public_effect_seams
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      denied_gateway = Object.new
      denied_gateway.define_singleton_method(:perform!) do |**|
        raise Hive::Patrol::EffectGateway::Denied.new("owner changed", nil)
      end
      store.instance_variable_set(:@state_effect_gateway, denied_gateway)
      store.instance_variable_set(:@effect_capture, capture)

      cycle_error = assert_raises(Hive::ConfigError) do
        store.perform_cycle_effect!(
          sink: "attempt", target: "attempts/fingerprint-1",
          idempotency_key: "attempt-1", capability: "repository_write"
        ) { {} }
      end

      uncertain_gateway = Object.new
      uncertain_gateway.define_singleton_method(:perform!) do |**|
        raise Hive::Patrol::EffectGateway::ReconciliationRequired.new(
          "delivery uncertain"
        )
      end
      store.instance_variable_set(:@state_effect_gateway, uncertain_gateway)
      write_error = assert_raises(Hive::ConfigError) do
        store.update_state("last_run_at" => NOW.iso8601)
      end

      assert_match(/owner changed/, cycle_error.message)
      assert_match(/delivery uncertain/, write_error.message)
    end
  end

  def test_fingerprint_mutation_holds_lock_during_gateway_admission
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      events = []
      store.define_singleton_method(:with_fingerprint_lock) do |**, &operation|
        events << :lock_entered
        operation.call
      ensure
        events << :lock_released
      end
      denied = Object.new
      denied.define_singleton_method(:perform!) do |**|
        events << :gateway_admission
        raise Hive::Patrol::EffectGateway::Denied.new(
          "owner changed", nil
        )
      end
      store.instance_variable_set(:@state_effect_gateway, denied)
      store.instance_variable_set(:@effect_capture, capture)

      error = assert_raises(Hive::Patrol::EffectGateway::Denied) do
        store.mutate_fingerprints!(
          fingerprint: "fp-1",
          idempotency_key: "fp-1:publish",
          scope: { "fingerprint" => "fp-1" },
          set: { "state" => "open" },
          deleted: []
        )
      end

      assert_match(/owner changed/, error.message)
      assert_equal(
        %i[lock_entered gateway_admission lock_released],
        events
      )
      refute_path_exists File.join(store.root, "fingerprints.lock")
    end
  end

  def test_fingerprint_mutation_has_an_exact_reconciliation_contract
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      gateway = Object.new
      captured = nil
      gateway.define_singleton_method(:perform!) do |**attributes, &effect|
        captured = attributes.fetch(:reconcile)
        effect.call
      end
      store.instance_variable_set(:@state_effect_gateway, gateway)
      store.instance_variable_set(:@effect_capture, capture)
      expected = {
        "state" => "open",
        "branch" => "patrol/fp-1"
      }

      outcome = store.mutate_fingerprints!(
        fingerprint: "fp-1",
        idempotency_key: "fp-1:publish",
        scope: { "fingerprint" => "fp-1" },
        set: expected,
        deleted: [ "publication_binding" ]
      )

      assert_match(/\A[0-9a-f]{64}\z/,
                   outcome.fetch("content_digest"))
      matched = captured.call(nil)
      assert_equal "matched", matched.fetch("status")
      assert_equal outcome, matched.fetch("outcome")

      store.send(:with_fingerprint_lock) do
        rows = store.fingerprints
        rows.fetch("fp-1")["state"] = "closed"
        store.send(:raw_write_fingerprints, rows)
      end
      assert_equal "ambiguous", captured.call(nil).fetch("status")
    end
  end

  def test_uncertain_fingerprint_effect_is_recovered_before_later_reads
    with_tmp_dir do |root|
      evidence_root = File.join(root, "evidence")
      store = configured_store(root, evidence_root)
      original_settle = store.method(:settle_effect!)
      crashed = false
      store.define_singleton_method(:settle_effect!) do |intent, **options|
        unless crashed
          crashed = true
          raise IOError, "crash after fingerprint write"
        end
        original_settle.call(intent, **options)
      end

      assert_raises(IOError) do
        store.mutate_fingerprints!(
          fingerprint: "fp-written",
          idempotency_key: "fp-written:open",
          scope: { "fingerprint" => "fp-written" },
          set: { "state" => "open" },
          deleted: [],
          replace: true
        )
      end
      assert_equal "open",
                   store.fingerprints.dig("fp-written", "state")

      reloaded = configured_store(root, evidence_root)
      recovered = reloaded.recover_pending_fingerprint_effects!

      assert_equal 1, recovered.length
      assert_equal "reconciled",
                   reloaded.occurrence(capture.occurrence_id)
                     .fetch("effects").values.first.fetch("state")
    end
  end

  def test_later_occurrence_recovers_a_predecessor_before_fingerprint_reads
    with_tmp_dir do |root|
      evidence_root = File.join(root, "evidence")
      predecessor = capture
      store = configured_store(
        root, evidence_root, capture_value: predecessor
      )
      original_settle = store.method(:settle_effect!)
      crashed = false
      store.define_singleton_method(:settle_effect!) do |intent, **options|
        unless crashed
          crashed = true
          raise IOError, "crash after predecessor fingerprint write"
        end
        original_settle.call(intent, **options)
      end
      assert_raises(IOError) do
        store.mutate_fingerprints!(
          fingerprint: "fp-predecessor",
          idempotency_key: "fp-predecessor:open",
          scope: { "fingerprint" => "fp-predecessor" },
          set: { "state" => "open" },
          deleted: [],
          replace: true
        )
      end

      successor = capture(identity: "manual-2", at: NOW + 60)
      reloaded = configured_store(
        root, evidence_root, capture_value: successor
      )
      recovered = reloaded.recover_pending_fingerprint_effects!

      assert_equal 1, recovered.length
      assert_equal "reconciled",
                   reloaded.occurrence(predecessor.occurrence_id)
                     .fetch("effects").values.first.fetch("state")
      assert_empty reloaded.occurrence(successor.occurrence_id)
                           .fetch("effects")
    end
  end

  def test_absent_uncertain_fingerprint_effect_is_safely_redispatched
    with_tmp_dir do |root|
      evidence_root = File.join(root, "evidence")
      store = configured_store(root, evidence_root)
      original_write = store.method(:raw_write_fingerprints)
      crashed = false
      store.define_singleton_method(:raw_write_fingerprints) do |data|
        unless crashed
          crashed = true
          raise "crash before write"
        end
        original_write.call(data)
      end
      assert_raises(RuntimeError) do
        store.mutate_fingerprints!(
          fingerprint: "fp-absent",
          idempotency_key: "fp-absent:open",
          scope: { "fingerprint" => "fp-absent" },
          set: { "state" => "open" },
          deleted: [],
          replace: true
        )
      end
      assert_nil store.fingerprints["fp-absent"]

      reloaded = configured_store(root, evidence_root)
      recovered = reloaded.recover_pending_fingerprint_effects!

      assert_equal 1, recovered.length
      assert_equal "open",
                   reloaded.fingerprints.dig("fp-absent", "state")
      assert_equal "committed",
                   reloaded.occurrence(capture.occurrence_id)
                     .fetch("effects").values.first.fetch("state")
    end
  end

  def test_attempt_reconciliation_distinguishes_absent_ambiguous_and_exact_match
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      assert_equal(
        { "status" => "absent", "outcome" => {} },
        store.reconcile_attempt("fingerprint-1")
      )

      store.instance_variable_set(:@effect_capture, capture)
      FileUtils.mkdir_p(File.join(store.root, "patches"))
      write_patch_record(
        store, "foreign",
        "patrol_occurrence_id" => "occ-#{'f' * 64}",
        "fingerprint" => "fingerprint-1"
      )
      assert_equal(
        { "status" => "absent", "outcome" => {} },
        store.reconcile_attempt("fingerprint-1")
      )
    end

    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.instance_variable_set(:@effect_capture, capture)
      FileUtils.mkdir_p(File.join(store.root, "patches"))
      %w[first second].each do |id|
        write_patch_record(
          store, id,
          "patrol_occurrence_id" => capture.occurrence_id,
          "fingerprint" => "fingerprint-1",
          "id" => id
        )
      end

      assert_equal(
        { "status" => "ambiguous", "outcome" => {} },
        store.reconcile_attempt("fingerprint-1")
      )
    end

    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.instance_variable_set(:@effect_capture, capture)
      FileUtils.mkdir_p(File.join(store.root, "patches"))
      record = {
        "patrol_occurrence_id" => capture.occurrence_id,
        "fingerprint" => "fingerprint-1",
        "id" => "only"
      }
      write_patch_record(store, "only", record)

      assert_equal(
        { "status" => "matched", "outcome" => { "patch_id" => "only" } },
        store.reconcile_attempt("fingerprint-1")
      )
    end
  end

  def test_effect_reconciliation_compares_every_supported_product_target
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      store.instance_variable_set(:@effect_capture, capture)
      reconciliations = []
      gateway = Object.new
      gateway.define_singleton_method(:perform!) do |reconcile:, **, &_effect|
        reconciliations << reconcile.call(nil)
        Object.new
      end
      store.instance_variable_set(:@state_effect_gateway, gateway)

      store.send(:raw_update_state, "last_run_at" => NOW.iso8601)
      store.update_state("last_run_at" => NOW.iso8601)
      store.update_state("last_run_at" => (NOW + 1).iso8601)

      assert_equal "matched", reconciliations.fetch(0).fetch("status")
      assert_equal "absent", reconciliations.fetch(1).fetch("status")
      assert_equal "different", reconciliations.fetch(1).dig("outcome", "observed")

      store.write_json(File.join(store.root, "fingerprints.json"), { "fp" => "active" })
      store.write_json(File.join(store.root, "dismissed.json"), { "fp" => "closed" })
      store.write_json(File.join(store.root, "features", "feature-1.json"), { "id" => "feature-1" })

      assert_equal({ "last_run_at" => NOW.iso8601 }, store.send(:effect_target_value, "state"))
      assert_equal({ "fp" => "active" }, store.send(:effect_target_value, "fingerprints"))
      assert_equal({ "fp" => "closed" }, store.send(:effect_target_value, "dismissed"))
      assert_equal({ "id" => "feature-1" }, store.send(:effect_target_value, "features/feature-1"))
      assert_nil store.send(:effect_target_value, "features/missing")
      assert_nil store.send(:effect_target_value, "unsupported/value")
      assert_nil store.send(:effect_target_value, "features")
    end
  end

  def test_effect_recovery_values_and_fingerprint_lock_fail_closed
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)

      non_object = assert_raises(Hive::ConfigError) do
        store.send(:effect_object, [])
      end
      non_json = assert_raises(Hive::ConfigError) do
        store.send(:effect_object, { "value" => Float::NAN })
      end
      FileUtils.mkdir_p(File.join(store.root, "fingerprints.lock"))
      gateway = Object.new
      gateway.define_singleton_method(:perform!) do |**_attributes, &effect|
        effect.call
      end
      store.instance_variable_set(:@state_effect_gateway, gateway)
      store.instance_variable_set(:@effect_capture, capture)
      lock_error = assert_raises(Hive::ConfigError) do
        store.mutate_fingerprints!(
          fingerprint: "fingerprint-1",
          idempotency_key: "mapping-1",
          scope: {},
          set: { "state" => "open" },
          deleted: []
        )
      end

      assert_equal "patrol effect recovery state is malformed", non_object.message
      assert_equal "patrol effect recovery state is malformed", non_json.message
      assert_match(/patrol fingerprint lock is unavailable/, lock_error.message)
    end
  end

  def test_patch_record_validates_the_requested_identity
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      FileUtils.mkdir_p(File.join(store.root, "patches"))
      record = {
        "id" => "patch-1",
        "fingerprint" => "fingerprint-1"
      }
      write_patch_record(store, "patch-1", record)

      assert_equal record, store.patch_record("patch-1")

      malformed = assert_raises(Hive::ConfigError) do
        store.patch_record("../escape")
      end
      assert_match(/identity is malformed/, malformed.message)

      write_patch_record(
        store,
        "wrong",
        "id" => "different",
        "fingerprint" => "fingerprint-2"
      )
      unavailable = assert_raises(Hive::ConfigError) do
        store.patch_record("wrong")
      end
      assert_match(/record is unavailable/, unavailable.message)
    end
  end

  private

  def configured_store(root, evidence_root, capture_value: capture)
    store = Hive::Patrol::StateStore.new(root)
    store.ensure!
    store.configure_effect_gateway!(
      capture: capture_value,
      evidence_store:
        Hive::Modules::Migration::EvidenceStore.new(root: evidence_root),
      config_loader:
        ->(_path) { { "patrol" => { "enabled" => true } } },
      capability_checker: ->(**) { true }
    )
    store
  end

  def outbox_entry(kind, bytes)
    {
      "id" => "outbox-1",
      "kind" => kind,
      "bytes" => bytes,
      "digest" => "digest-1"
    }
  end

  def write_patch_record(store, id, record)
    store.write_json(
      File.join(store.root, "patches", "#{id}.json"),
      record
    )
  end

  def perform_attempt(store, patch)
    store.perform_cycle_effect!(
      sink: "attempt",
      target: "attempts/fingerprint-1",
      idempotency_key: "reservation-1:attempt:fingerprint-1",
      capability: "repository_write",
      reconcile: ->(_intent) { store.reconcile_attempt("fingerprint-1") }
    ) do
      store.write_patch("patch-1", patch)
      { "patch_id" => "patch-1" }
    end
  end

  def effect_intent
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: capture.occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "pull_request",
      target: "owner/demo:hive-patrol/fix",
      idempotency_key: "fingerprint-1:pr",
      capability: "github_pull_requests",
      scope: {
        "repository" => "owner/demo",
        "branch" => "hive-patrol/fix",
        "base_branch" => "main",
        "finding_projection" =>
          Hive::Modules::Migration::PatrolEvidence.canonical(
            "category" => "correctness",
            "feature_id" => "feature-1",
            "root_cause_tokens" => [ "shared", "cause" ],
            "target_sha" => "a" * 40,
            "title_tokens" => [ "shared", "title" ]
          ),
        "fingerprint" => "fingerprint-1",
        "patch_id" => "patch-1",
        "worktree_path" => "/tmp/patrol-patch-1",
        "base_sha" => "a" * 40,
        "head_sha" => "b" * 40
      },
      created_at: NOW
    )
  end

  def publication_outcome
    {
      "pr_url" => "https://github.com/owner/demo/pull/7",
      "state" => "OPEN",
      "head_oid" => "b" * 40,
      "base_oid" => "a" * 40
    }
  end

  def fingerprint_intent(predecessor, idempotency_key:, deleted:)
    operation = {
      "deleted" => deleted,
      "fingerprint" => "shared",
      "replace" => false,
      "set" => { "state" => "open" }
    }
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: predecessor.occurrence_id,
      authority: "legacy",
      owner_epoch: predecessor.owner_epoch,
      sink: "state",
      target: "fingerprints/shared",
      idempotency_key: idempotency_key,
      capability: "filesystem_write",
      scope: {
        "fingerprint" => "shared",
        "fingerprint_operation" => JSON.generate(operation)
      },
      created_at: predecessor.recorded_at
    )
  end

  def capture(identity: "manual-1", at: NOW, project: nil)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: project || {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "manual", "id" => identity },
      reservation: { "kind" => "ordinary", "id" => identity },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "state-store-test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: at,
      recorded_at: at
    )
  end
end
