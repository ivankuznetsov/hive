require "test_helper"
require "tmpdir"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_adapter"
require "hive/patrol/state_store"

class PatrolFixAdmissionAdapterTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_publishes_directly_into_the_admission_store
    Dir.mktmpdir do |dir|
      adapter = Hive::Patrol::FixAdmissionAdapter.new(root: dir)
      entry = adapter.publish_finding!(finding, accepted_at: NOW)
      replay = adapter.publish_finding!(finding, accepted_at: NOW + 60)

      assert_equal entry, replay
      assert_equal "ordinary_patrol", entry.dig("source", "engine")
      assert_equal "pending", entry.fetch("status")
      assert_equal [ entry.fetch("occurrence_id") ],
                   adapter.store.pending.map { |item| item.fetch("occurrence_id") }
      assert adapter.published?(entry.fetch("occurrence_id"))
      %i[pending park! defer! resume! acknowledge! settle!].each do |method|
        refute_respond_to adapter, method
      end
    end
  end

  def test_state_store_acceptance_boundary_publishes_directly
    Dir.mktmpdir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::Patrol::StateStore.new(dir, hive_state_path: hive_state)
      store.ensure!
      store.write_finding(finding)

      adapter = store.patrol_fix_admission_adapter
      assert_equal 1, adapter.store.pending.length
      assert_equal File.join(hive_state, "patrol-fix", "admissions"), adapter.store.root
    end
  end

  def test_snapshot_conversion_includes_file_evidence_paths
    source = Hive::Patrol::Finding.from_h(
      finding.to_h.merge("scope" => {}, "evidence" => [ { "file" => "lib/hive/patrol.rb" } ])
    )

    snapshot = Hive::Patrol::FixAdmissionAdapter.snapshot_for(source, accepted_at: NOW)

    assert_equal [ "lib/hive/patrol.rb" ], snapshot.to_h.fetch("affected_code")
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
