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

  def test_non_persisting_admission_updates_only_the_in_memory_lifecycle
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.ensure!
      store.write_finding(finding(id: "old", target_sha: "a" * 40, state: "active"))
      persisted = File.binread(File.join(store.root, "findings", "old.json"))

      registry = Hive::Patrol::FindingRegistry.new(
        state: store, target_sha: "b" * 40,
        clock: -> { Time.utc(2026, 7, 22, 12) }
      )
      result = registry.admit([ finding(id: "new") ], persist: false)

      assert_equal "superseded",
                   registry.instance_variable_get(:@existing).fetch(0).lifecycle_state
      assert_equal "new", result.findings.fetch(0).id
      assert_equal persisted, File.binread(File.join(store.root, "findings", "old.json"))
    end
  end

  def test_state_store_rejects_malformed_feature_batches
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      feature = Struct.new(:id).new("")

      assert_raises(Hive::ConfigError) { store.write_features([ feature ]) }

      valid = Hive::Patrol::Feature.new(
        id: "queue", kind: "service", entrypoints: [ "queue.rb" ],
        owned_files: [ "queue.rb" ], context_files: [], tests: []
      )
      assert_equal [ valid ], store.write_features([ valid ])
      assert File.file?(File.join(store.root, "features", "queue.json"))
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
