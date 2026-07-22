require "test_helper"
require "hive/patrol/finding"
require "hive/patrol/finding_registry"
require "hive/patrol/state_store"

class HivePatrolFindingRegistryTest < Minitest::Test
  include HiveTestHelper

  def finding(id:, target_sha: nil, state: nil, title: "Queue loses acknowledged work",
              root_cause: "The acknowledgement is persisted before the queue item")
    Hive::Patrol::Finding.new(
      id: id, feature_id: "queue", category: "bug", severity: "high",
      confidence: "high", title: title,
      description: "A reachable interruption drops committed work.",
      recommendation: "Persist the queue item before its acknowledgement.",
      scope: "feature", contract: "Acknowledged work remains recoverable.",
      impact: "A caller permanently loses an accepted operation.",
      root_cause: root_cause,
      reproduction: "Interrupt between acknowledgement and the queue write.",
      validation: "Run the focused queue regression.", validation_key: "test",
      evidence: [ { "file" => "queue.rb", "line" => 1, "snippet" => "ack" } ],
      fingerprint: "fp-#{id}", target_sha: target_sha,
      lifecycle_state: state
    )
  end

  def test_same_target_semantic_duplicate_is_not_persisted
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      existing = finding(id: "old", target_sha: "a" * 40, state: "active")
      store.write_finding(existing)
      current = finding(
        id: "new", title: "Acknowledged queue work is lost",
        root_cause: existing.root_cause, target_sha: nil
      )

      result = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "a" * 40
      ).admit([ current ])

      assert_empty result.findings
      assert_empty result.persistable_findings
      assert_equal "semantic_duplicate", result.skipped.first.fetch("reason")
      assert_equal "old", result.skipped.first.fetch("canonical_finding_id")
      refute File.exist?(File.join(store.root, "findings", "new.json"))
    end
  end

  def test_newer_evidence_supersedes_active_record_before_new_record_is_written
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      store.write_finding(finding(id: "old", target_sha: "a" * 40, state: "active"))
      current = finding(id: "new")
      registry = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "b" * 40,
        clock: -> { Time.utc(2026, 7, 22, 12, 0, 0) }
      )

      result = registry.admit([ current ])

      assert_equal [ current ], result.findings
      assert_equal [ current ], result.persistable_findings
      old = store.findings.find { |item| item.id == "old" }
      assert_equal "superseded", old.lifecycle_state
      assert_equal "new", old.superseded_by
      assert_equal "active", current.lifecycle_state
      assert_equal "b" * 40, current.target_sha
      refute File.exist?(File.join(store.root, "findings", "new.json")),
             "the command persists admitted records only after scoring"
    end
  end

  def test_shipping_retry_reuses_same_target_active_record_without_persisting_the_duplicate
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      existing = finding(id: "old", target_sha: "a" * 40, state: "active")
      store.write_finding(existing)

      result = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "a" * 40
      ).admit([ finding(id: "new") ], retry_active: true)

      assert_equal [ "old" ], result.findings.map(&:id)
      assert_empty result.persistable_findings
      assert_empty result.skipped
      assert_equal [ "old" ], store.findings.map(&:id)
    end
  end

  def test_same_target_terminal_record_still_suppresses_a_duplicate
    %w[resolved rejected].each do |terminal_state|
      with_tmp_dir do |dir|
        store = Hive::Patrol::StateStore.new(dir)
        store.ensure!
        store.write_finding(finding(id: "old", target_sha: "a" * 40, state: terminal_state))

        result = Hive::Patrol::FindingRegistry.new(
          state: store, target_sha: "a" * 40
        ).admit([ finding(id: "new") ], retry_active: true)

        assert_empty result.findings
        assert_equal "old", result.skipped.first.fetch("canonical_finding_id")
      end
    end
  end

  def test_new_target_admits_recurrence_after_resolved_or_rejected_record
    %w[resolved rejected].each do |terminal_state|
      with_tmp_dir do |dir|
        store = Hive::Patrol::StateStore.new(dir)
        store.ensure!
        store.write_finding(finding(id: "old", target_sha: "a" * 40, state: terminal_state))
        recurrence = finding(id: "new")

        result = Hive::Patrol::FindingRegistry.new(
          state: store, target_sha: "b" * 40
        ).admit([ recurrence ], retry_active: true)

        assert_equal [ recurrence ], result.findings
        assert_equal [ recurrence ], result.persistable_findings
        assert_empty result.skipped
        assert_equal "active", recurrence.lifecycle_state
        assert_equal "recurrence_after_terminal", recurrence.lifecycle_reason
        assert_equal "b" * 40, recurrence.target_sha
      end
    end
  end

  def test_old_terminal_ledger_does_not_redisposition_a_newer_recurrence
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      old = finding(id: "old", target_sha: "a" * 40, state: "resolved")
      store.write_finding(old)
      recurrence = finding(id: "new")
      recurrence.fingerprint = old.fingerprint
      registry = Hive::Patrol::FindingRegistry.new(state: store, target_sha: "b" * 40)
      result = registry.admit([ recurrence ], retry_active: true)
      store.write_finding(result.persistable_findings.fetch(0))
      registry = Hive::Patrol::FindingRegistry.new(state: store, target_sha: "b" * 40)

      registry.reconcile!(
        fingerprints: {
          old.fingerprint => { "state" => "merged", "target_sha" => "a" * 40 }
        },
        dismissed: {}
      )

      states = store.findings.to_h { |item| [ item.id, item.lifecycle_state ] }
      assert_equal "resolved", states.fetch("old")
      assert_equal "active", states.fetch("new")

      registry.reconcile!(
        fingerprints: {
          old.fingerprint => { "state" => "merged", "target_sha" => "b" * 40 }
        },
        dismissed: {}
      )

      recurrence_state = store.findings.find { |item| item.id == "new" }.lifecycle_state
      assert_equal "resolved", recurrence_state,
                   "terminal evidence for the recurrence's own target must still close it"
    end
  end

  def test_reconciles_merged_and_dismissed_ledgers_to_terminal_states
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      merged = finding(id: "merged", state: "active")
      dismissed = finding(id: "dismissed", state: "active")
      store.write_finding(merged)
      store.write_finding(dismissed)
      registry = Hive::Patrol::FindingRegistry.new(state: store, target_sha: "c" * 40)

      registry.reconcile!(
        fingerprints: { merged.fingerprint => { "state" => "merged" } },
        dismissed: { dismissed.fingerprint => { "state" => "dismissed" } }
      )

      states = store.findings.to_h { |item| [ item.id, item.lifecycle_state ] }
      assert_equal "resolved", states.fetch("merged")
      assert_equal "rejected", states.fetch("dismissed")
    end
  end

  def test_reconciliation_reuses_loaded_records_and_one_timestamp_per_transition
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      record = finding(id: "merged", state: "active")
      store.write_finding(record)
      reads = 0
      original_findings = store.method(:findings)
      store.define_singleton_method(:findings) do
        reads += 1
        original_findings.call
      end
      clock_calls = 0
      now = Time.utc(2026, 7, 22, 12, 0, 0)
      registry = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "c" * 40,
        clock: -> { clock_calls += 1; now }
      )

      registry.reconcile!(
        fingerprints: { record.fingerprint => { "state" => "merged" } },
        dismissed: {}
      )

      assert_equal 1, reads
      assert_equal 1, clock_calls
      assert_equal now.iso8601, original_findings.call.first.lifecycle_updated_at
    end
  end

  def test_in_memory_transition_updates_lifecycle_without_persisting
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      record = finding(id: "memory", state: "active")
      now = Time.utc(2026, 7, 22, 13, 0, 0)
      registry = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "a" * 40, clock: -> { now }
      )

      transitioned = registry.transition_current!(
        record, state: "superseded", reason: "newer_target_evidence", persist: false
      )

      assert_same record, transitioned
      assert_equal "superseded", record.lifecycle_state
      assert_equal "newer_target_evidence", record.lifecycle_reason
      assert_equal now.iso8601, record.lifecycle_updated_at
      assert_nil record.superseded_by
      assert_empty store.findings
    end
  end

  def test_state_store_ignores_invalid_finding_records
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      File.write(
        File.join(store.root, "findings", "invalid.json"),
        JSON.generate("id" => "missing-required-fields")
      )

      assert_empty store.findings
    end
  end

  def test_state_store_transitions_by_id_and_rejects_unknown_states
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      store.write_finding(finding(id: "stored", state: "active"))

      assert_raises(ArgumentError) do
        store.transition_finding("stored", state: "unknown", reason: "invalid")
      end
      store.transition_finding(
        "stored", state: "resolved", reason: "patrol_pr_merged",
        now: Time.utc(2026, 7, 22, 14, 0, 0)
      )
      transitioned = store.findings.fetch(0)

      assert_equal "stored", transitioned.id
      assert_equal "resolved", transitioned.lifecycle_state
      assert_equal "patrol_pr_merged", transitioned.lifecycle_reason
    end
  end
end
