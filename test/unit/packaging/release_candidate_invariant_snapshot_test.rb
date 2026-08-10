require "test_helper"
require "json"
require_relative "../../../packaging/release_candidate/invariant_snapshot"

class ReleaseCandidateInvariantSnapshotTest < Minitest::Test
  include HiveTestHelper

  REQUIRED = %w[
    channel_sidecars configuration default_workflow dependencies
    dispatch_receipts durable_attempts global_registry install_identity
    managed_web_data markers project_registry service_definitions status_json
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

  def test_missing_required_named_invariant_and_symlinked_capture_root_fail_closed
    missing = state("task body" => "keep")
    missing.delete("durable_attempts")
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::InvariantSnapshot.build(row_id: "latest-stable", sections: missing)
    end
    assert_includes error.message, "durable_attempts"

    with_tmp_dir do |dir|
      outside = File.join(dir, "outside")
      root = File.join(dir, "root")
      FileUtils.mkdir_p([ outside, root ])
      File.write(File.join(outside, "secret"), "do not read")
      File.symlink(outside, File.join(root, "linked"))

      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::InvariantSnapshot.capture_tree(
          root: root, sections: { "tasks" => "linked" }
        )
      end
      assert_includes error.message, "symlink"
    end
  end

  def test_status_and_doctor_ignore_timestamp_order_version_and_binary_noise
    first = state("task body" => "keep")
    first["status_json"] = {
      "schema" => "hive-status", "schema_version" => 6,
      "generated_at" => "2026-01-01T00:00:00Z", "version" => "0.6.9",
      "tasks" => [ { "id" => 2, "blocked" => false }, { "id" => 1, "blocked" => true } ]
    }
    first["doctor_json"] = {
      "schema" => "hive-doctor", "binary_path" => "/baseline/bin/hive",
      "rows" => [ { "name" => "codex", "healthy" => true } ]
    }
    second = Marshal.load(Marshal.dump(first))
    second["status_json"]["schema_version"] = 7
    second["status_json"]["generated_at"] = "2026-07-27T12:00:00Z"
    second["status_json"]["version"] = "0.7.0"
    second["status_json"]["tasks"].reverse!
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

  def test_status_ignores_elapsed_age_and_additive_empty_defaults
    first = state("task body" => "keep")
    first["status_json"] = {
      "schema" => "hive-status",
      "projects" => [ { "name" => "hive", "tasks" => [ { "id" => 7 } ] } ]
    }
    second = Marshal.load(Marshal.dump(first))
    project = second["status_json"]["projects"][0]
    project["hidden_archived_task_count"] = 0
    project["tasks"][0].merge!(
      "age_seconds" => 4,
      "observation_mtime" => "2026-08-06T00:48:15.176470Z",
      "closure" => nil,
      "outcomes" => []
    )

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

  def test_status_keeps_nonempty_archive_closure_and_outcome_state
    first = state("task body" => "keep")
    first["status_json"] = {
      "schema" => "hive-status",
      "projects" => [ { "name" => "hive", "tasks" => [ { "id" => 7 } ] } ]
    }
    second = Marshal.load(Marshal.dump(first))
    project = second["status_json"]["projects"][0]
    project["hidden_archived_task_count"] = 1
    project["tasks"][0].merge!(
      "closure" => { "status" => "operator_required" },
      "outcomes" => [ { "name" => "approve" } ]
    )

    before = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: first
    )
    after = HiveReleaseCandidate::InvariantSnapshot.build(
      row_id: "latest-stable", sections: second
    )
    paths = HiveReleaseCandidate::InvariantSnapshot.compare(
      before: before, after: after, allowed_migrations: []
    ).fetch("unexpected").map { |item| item.fetch("path") }

    assert_equal(
      [
        "/status_json/projects/0/hidden_archived_task_count",
        "/status_json/projects/0/tasks/0/closure",
        "/status_json/projects/0/tasks/0/outcomes"
      ],
      paths
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
