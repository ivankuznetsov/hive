require "test_helper"
require "tmpdir"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_outbox"
require "hive/patrol/state_store"
require "hive/patrol_fix/cutover_gate"

class PatrolFixAdmissionOutboxTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_default_disabled_gate_preserves_legacy_and_enabled_gate_publishes_and_acks
    Dir.mktmpdir do |dir|
      disabled = Hive::Patrol::FixAdmissionOutbox.new(root: dir)
      assert_nil disabled.publish_finding!(finding, accepted_at: NOW)
      assert_empty disabled.pending

      enabled = Hive::Patrol::FixAdmissionOutbox.new(
        root: dir,
        gate: Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
      )
      entry = enabled.publish_finding!(finding, accepted_at: NOW)
      replay = enabled.publish_finding!(finding, accepted_at: NOW + 60)

      assert_equal entry, replay
      assert_equal "ordinary_patrol", entry.dig("snapshot", "engine")
      assert_equal "pending", entry.fetch("status")
      assert_equal [ entry.fetch("occurrence_id") ],
                   enabled.pending.map { |item| item.fetch("occurrence_id") }

      receipt = enabled.acknowledge!(
        occurrence_id: entry.fetch("occurrence_id"),
        admission_id: entry.fetch("occurrence_id"),
        task: { "slug" => "repair-refresh-abc123", "generation" => 1,
                "evidence_digest" => "a" * 64 },
        now: NOW
      )
      assert_match(/ordinary_patrol:/, receipt)
      assert_equal [ entry.fetch("occurrence_id") ],
                   enabled.pending.map { |item| item.fetch("occurrence_id") }
      enabled.settle!(occurrence_id: entry.fetch("occurrence_id"), now: NOW)
      assert_empty enabled.pending
      assert enabled.acknowledged?(entry.fetch("occurrence_id"))
      refute enabled.legacy_downstream_allowed?(finding)
    end
  end

  def test_state_store_acceptance_boundary_publishes_only_with_enabled_gate
    Dir.mktmpdir do |dir|
      hive_state = File.join(dir, ".hive-state")
      enabled = Hive::Patrol::StateStore.new(
        dir, hive_state_path: hive_state,
        patrol_fix_cutover_gate: Hive::PatrolFix::CutoverGate.new(
          enabled: true, epoch: "epoch-test"
        )
      )
      enabled.ensure!
      enabled.write_finding(finding)

      assert_equal 1, enabled.patrol_fix_admission_outbox.pending.length

      disabled_root = File.join(dir, "disabled-state")
      disabled = Hive::Patrol::StateStore.new(dir, hive_state_path: disabled_root)
      disabled.ensure!
      disabled.write_finding(finding)
      assert_empty disabled.patrol_fix_admission_outbox.pending
    end
  end

  def test_provider_retry_is_not_pending_again_until_its_durable_retry_time
    Dir.mktmpdir do |dir|
      enabled = Hive::Patrol::FixAdmissionOutbox.new(
        root: dir,
        gate: Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
      )
      entry = enabled.publish_finding!(finding, accepted_at: NOW)

      enabled.defer!(
        occurrence_id: entry.fetch("occurrence_id"), retry_at: NOW + 300, now: NOW
      )

      assert_empty enabled.pending(now: NOW + 299)
      assert_equal [ entry.fetch("occurrence_id") ],
                   enabled.pending(now: NOW + 300).map { |record| record.fetch("occurrence_id") }
    end
  end

  private

  def finding
    Hive::Patrol::Finding.new(
      id: "finding-1", feature_id: "refresh", category: "bug",
      severity: "high", confidence: "high", title: "Repair refresh",
      description: "Refresh fails", recommendation: "Consolidate recovery",
      scope: "feature", contract: "Refresh remains usable", impact: "Sessions fail",
      root_cause: "Two owners race", reproduction: "Run the refresh spec",
      validation: "Run test/refresh_test.rb", evidence: [ "Reachable failure" ],
      fingerprint: "refresh-root", validation_key: "refresh-v1",
      target_sha: "1" * 40, lifecycle_state: "active",
      lifecycle_reason: "admitted", lifecycle_updated_at: NOW.iso8601
    )
  end
end
