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
      old = store.findings.find { |item| item.id == "old" }
      assert_equal "superseded", old.lifecycle_state
      assert_equal "new", old.superseded_by
      assert_equal "active", current.lifecycle_state
      assert_equal "b" * 40, current.target_sha
      refute File.exist?(File.join(store.root, "findings", "new.json")),
             "the command persists admitted records only after scoring"
    end
  end

  def test_terminal_record_suppresses_a_reworded_recurrence
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      store.write_finding(finding(id: "old", target_sha: "a" * 40, state: "resolved"))

      result = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "b" * 40
      ).admit([ finding(id: "new") ])

      assert_empty result.findings
      assert_equal "old", result.skipped.first.fetch("canonical_finding_id")
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
end
