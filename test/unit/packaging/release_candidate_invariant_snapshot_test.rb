require "test_helper"
require "json"
require_relative "../../../packaging/release_candidate/invariant_snapshot"

class ReleaseCandidateInvariantSnapshotTest < Minitest::Test
  include HiveTestHelper

  REQUIRED = %w[
    channel_sidecars configuration default_workflow dependencies
    dispatch_receipts durable_attempts global_registry install_identity
    managed_web_data markers project_registry service_definitions
    doctor_json tasks
  ].freeze

  def test_normalizes_named_invariants_and_reports_only_unapproved_changes
    before = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: state("task body" => "keep")
    )
    after = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable",
      sections: state("task body" => "changed").merge(
        "install_identity" => { "gem_sha256" => "b" * 64 }
      )
    )

    diff = HiveReleaseCandidate::InvariantSnapshot.compare(
      before: before, after: after,
      allowed_migrations: [ "/install_identity/gem_sha256" ]
    )

    refute diff.fetch("passed")
    assert_equal [ "/install_identity/gem_sha256" ], diff.fetch("allowed").map { |item| item.fetch("path") }
    assert_equal [ "/tasks/task body" ], diff.fetch("unexpected").map { |item| item.fetch("path") }
  end

  def test_missing_required_named_invariant_fails_closed
    missing = state("task body" => "keep")
    missing.delete("durable_attempts")
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::InvariantSnapshot.build(row_id: "latest-stable", sections: missing)
    end
    assert_includes error.message, "durable_attempts"
  end

  def test_doctor_ignores_timestamp_order_version_and_binary_noise
    first = state("task body" => "keep")
    first["doctor_json"] = {
      "schema" => "hive-doctor", "schema_version" => 6,
      "generated_at" => "2026-01-01T00:00:00Z", "version" => "0.6.9",
      "binary_path" => "/baseline/bin/hive",
      "rows" => [
        { "name" => "pi", "healthy" => false },
        { "name" => "codex", "healthy" => true }
      ]
    }
    second = Marshal.load(Marshal.dump(first))
    second["doctor_json"]["schema_version"] = 7
    second["doctor_json"]["generated_at"] = "2026-07-27T12:00:00Z"
    second["doctor_json"]["version"] = "0.7.0"
    second["doctor_json"]["rows"].reverse!
    second["doctor_json"]["binary_path"] = "/candidate/bin/hive"

    before = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: first
    )
    after = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: second
    )

    assert HiveReleaseCandidate::InvariantSnapshot.compare(
      before: before, after: after, allowed_migrations: []
    ).fetch("passed")
  end

  def test_doctor_ignores_version_owned_managed_skill_expectations_but_not_observed_state
    first = state("task body" => "keep")
    first["doctor_json"] = {
      "schema" => "hive-doctor",
      "managed_skills" => [ {
        "stage" => "hive.operations",
        "expected" => { "version" => "0.6.9", "canonical_digest" => "a" * 64 },
        "native" => { "available" => true, "tree_digest" => "c" * 64 }
      } ]
    }
    second = Marshal.load(Marshal.dump(first))
    second["doctor_json"]["managed_skills"][0]["expected"] = {
      "version" => "0.7.0", "canonical_digest" => "b" * 64
    }

    before = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: first
    )
    after = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: second
    )
    assert HiveReleaseCandidate::InvariantSnapshot.compare(
      before: before, after: after, allowed_migrations: []
    ).fetch("passed")

    second["doctor_json"]["managed_skills"][0]["native"]["tree_digest"] = "d" * 64
    changed = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: second
    )
    diff = HiveReleaseCandidate::InvariantSnapshot.compare(
      before: before, after: changed, allowed_migrations: []
    )

    refute diff.fetch("passed")
    assert_equal(
      [ "/doctor_json/managed_skills/0/native/tree_digest" ],
      diff.fetch("unexpected").map { |item| item.fetch("path") }
    )
  end

  private

  def state(tasks)
    REQUIRED.to_h do |name|
      value = if name == "tasks"
                tasks
      elsif name == "install_identity"
                { "gem_sha256" => "a" * 64 }
      else
                { "value" => name }
      end
      [ name, value ]
    end
  end
end
