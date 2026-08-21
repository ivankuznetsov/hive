require "test_helper"
require "tmpdir"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_outbox"
require "hive/patrol/state_store"

class PatrolFixAdmissionOutboxTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_publishes_and_acknowledges_directly
    Dir.mktmpdir do |dir|
      outbox = Hive::Patrol::FixAdmissionOutbox.new(root: dir)
      entry = outbox.publish_finding!(finding, accepted_at: NOW)
      replay = outbox.publish_finding!(finding, accepted_at: NOW + 60)

      assert_equal entry, replay
      assert_equal "ordinary_patrol", entry.dig("snapshot", "engine")
      assert_equal "pending", entry.fetch("status")
      assert_equal [ entry.fetch("occurrence_id") ],
                   outbox.pending.map { |item| item.fetch("occurrence_id") }

      receipt = outbox.acknowledge!(
        occurrence_id: entry.fetch("occurrence_id"),
        admission_id: entry.fetch("occurrence_id"),
        task: { "slug" => "repair-refresh-abc123", "generation" => 1,
                "evidence_digest" => "a" * 64 },
        now: NOW
      )
      assert_match(/ordinary_patrol:/, receipt)
      assert_equal [ entry.fetch("occurrence_id") ],
                   outbox.pending.map { |item| item.fetch("occurrence_id") }
      outbox.settle!(occurrence_id: entry.fetch("occurrence_id"), now: NOW)
      assert_empty outbox.pending
      assert outbox.acknowledged?(entry.fetch("occurrence_id"))
    end
  end

  def test_state_store_acceptance_boundary_publishes_directly
    Dir.mktmpdir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::Patrol::StateStore.new(dir, hive_state_path: hive_state)
      store.ensure!
      store.write_finding(finding)

      assert_equal 1, store.patrol_fix_admission_outbox.pending.length
    end
  end

  def test_provider_retry_is_not_pending_again_until_its_durable_retry_time
    Dir.mktmpdir do |dir|
      outbox = Hive::Patrol::FixAdmissionOutbox.new(root: dir)
      entry = outbox.publish_finding!(finding, accepted_at: NOW)

      outbox.defer!(
        occurrence_id: entry.fetch("occurrence_id"), retry_at: NOW + 300, now: NOW
      )

      assert_empty outbox.pending(now: NOW + 299)
      assert_equal [ entry.fetch("occurrence_id") ],
                   outbox.pending(now: NOW + 300).map { |record| record.fetch("occurrence_id") }
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
