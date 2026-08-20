require "test_helper"
require "hive/patrol_fix/source_snapshot"

class PatrolFixSourceSnapshotTest < Minitest::Test
  def test_builds_bounded_canonical_bytes_and_evidence_digest
    snapshot = build_snapshot

    assert_equal snapshot.to_h, Hive::PatrolFix::SourceSnapshot.parse(snapshot.canonical_bytes).to_h
    assert_match(/\A[0-9a-f]{64}\z/, snapshot.digest)
    assert_match(/\A[0-9a-f]{64}\z/, snapshot.evidence_digest)
    assert snapshot.to_h.frozen?
  end

  def test_rejects_unsafe_paths_excessive_candidates_and_secrets_without_leaking_them
    unsafe = assert_raises(Hive::PatrolFix::SourceSnapshot::InvalidSnapshot) do
      build_snapshot(affected_code: [ "../outside.rb" ])
    end
    assert_includes unsafe.message, "relative repository paths"

    assert_raises(Hive::PatrolFix::SourceSnapshot::InvalidSnapshot) do
      build_snapshot(affected_code: Array.new(257) { |index| "lib/file#{index}.rb" })
    end

    secret = "github_pat_#{'a' * 30}"
    error = assert_raises(Hive::PatrolFix::SourceSnapshot::InvalidSnapshot) do
      build_snapshot(evidence: [ "observed #{secret}" ])
    end
    assert_includes error.message, "secret"
    refute_includes error.message, secret
  end

  private

  def build_snapshot(overrides = {})
    Hive::PatrolFix::SourceSnapshot.build(**{
      engine: "ordinary_patrol",
      identity: "finding-1",
      title: "Repair stale refresh handling",
      summary: "Refresh failures leave the request in an invalid state.",
      target_revision: "1" * 40,
      evidence: [ "The failing branch is reachable." ],
      affected_code: [ "lib/demo.rb" ],
      reproduction_guidance: "Run the focused request test.",
      discovery_run: "ordinary-run-1",
      semantic_lineage: [ "root-login-refresh" ],
      aliases: [],
      external_issues: [],
      existing_pull_requests: [],
      accepted_at: Time.utc(2026, 8, 20, 12).iso8601
    }.merge(overrides))
  end
end
