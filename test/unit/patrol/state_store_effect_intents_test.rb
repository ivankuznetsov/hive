require "test_helper"
require "hive/modules/migration/evidence_store"
require "hive/patrol/state_store"

class PatrolStateStoreEffectIntentsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_occurrence_journal_is_the_only_effect_recovery_authority
    with_tmp_dir do |root|
      store = Hive::Patrol::StateStore.new(root)
      store.ensure!
      intent = effect_intent
      store.reserve_occurrence!(capture, now: NOW)

      store.prepare_effect!(intent, now: NOW)
      store.mark_dispatch_uncertain!(intent, now: NOW)
      outcome = {
        "pr_url" => "https://github.com/owner/demo/pull/7"
      }
      receipt = store.settle_effect!(
        intent, status: "committed", outcome: outcome, now: NOW
      )

      reloaded = Hive::Patrol::StateStore.new(root)
      assert_equal "committed", reloaded.effect_state(intent).fetch("state")
      assert_equal receipt.to_h, reloaded.effect_receipt(
        receipt.receipt_id, occurrence_id: intent.occurrence_id
      ).to_h
      refute reloaded.state.key?("effect_intents")
      assert reloaded.fingerprints.values.none? do |entry|
        entry.is_a?(Hash) && entry.key?("effect_intents")
      end
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
      outcome = {
        "pr_url" => "https://github.com/owner/demo/pull/7"
      }
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
      store.write_finding(finding)
      perform_attempt(store, patch)
      receipt_count = evidence.receipts.size

      store.update_state("last_run_at" => NOW.iso8601)
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
      lock_error = assert_raises(Hive::ConfigError) do
        store.mutate_fingerprints { |_data| }
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
      created_at: NOW
    )
  end

  def capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
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
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
