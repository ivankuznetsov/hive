require "test_helper"
require_relative "../../../packaging/release_candidate/remote_identity"

class ReleaseCandidateRemoteIdentityTest < Minitest::Test
  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ACTION_LOCK = "c" * 64
  ARTIFACT_DIGEST = "sha256:#{'d' * 64}"

  def test_preflight_requires_protected_main_reachability_and_trusted_workflow_revision
    identity = HiveReleaseCandidate::RemoteIdentity.new(
      repository: "ivankuznetsov/hive",
      candidate_sha: SHA,
      workflow_sha: WORKFLOW_SHA,
      action_lock_sha256: ACTION_LOCK
    )

    result = identity.preflight!(
      repository: { "full_name" => "ivankuznetsov/hive", "default_branch" => "main" },
      branch: { "name" => "main", "protected" => true },
      comparison: { "status" => "behind", "base_sha" => WORKFLOW_SHA, "head_sha" => SHA },
      workflow: {
        "path" => ".github/workflows/release-candidate.yml",
        "state" => "active",
        "revision" => WORKFLOW_SHA
      }
    )

    assert_equal SHA, result.fetch("candidate_sha")
    assert_equal WORKFLOW_SHA, result.fetch("workflow_sha")
    assert_equal ACTION_LOCK, result.fetch("action_lock_sha256")
  end

  def test_preflight_rejects_unprotected_unreachable_or_wrong_workflow
    mutations = [
      [ "protected main", ->(parts) { parts[:branch]["protected"] = false } ],
      [ "reachable candidate", ->(parts) { parts[:comparison]["status"] = "diverged" } ],
      [ "comparison base", ->(parts) { parts[:comparison]["base_sha"] = "f" * 40 } ],
      [ "workflow revision", ->(parts) { parts[:workflow]["revision"] = "e" * 40 } ]
    ]

    mutations.each do |label, mutate|
      parts = valid_preflight
      mutate.call(parts)
      error = assert_raises(HiveReleaseCandidate::Error, label) do
        identity.preflight!(**parts)
      end
      refute_empty error.message
    end
  end

  def test_action_lock_covers_step_and_reusable_workflow_uses_and_rejects_mutable_refs
    lock = HiveReleaseCandidate::RemoteIdentity.action_lock(
      ".github/workflows/a.yml" => <<~YAML,
        steps:
          - uses: actions/checkout@#{'1' * 40}
          - name: named
            uses: ruby/setup-ruby@#{'2' * 40}
        reusable:
          uses: owner/workflows/.github/workflows/test.yml@#{'3' * 40}
        local:
          uses: ./.github/workflows/local.yml
      YAML
    )

    assert_equal 3, lock.fetch("entries").size
    assert_match(/\A[0-9a-f]{64}\z/, lock.fetch("sha256"))
    assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::RemoteIdentity.action_lock(
        ".github/workflows/a.yml" => "steps:\n  - uses: actions/checkout@v7\n"
      )
    end
  end

  def test_run_and_artifact_identity_are_exact
    result = identity.verify_run!(
      run: {
        "id" => 42, "run_attempt" => 2, "name" => "hive-release-candidate:req-abc123:#{SHA}",
        "event" => "workflow_dispatch", "status" => "completed", "conclusion" => "success",
        "head_sha" => WORKFLOW_SHA, "head_branch" => "main",
        "path" => ".github/workflows/release-candidate.yml",
        "head_repository" => { "full_name" => "ivankuznetsov/hive" }
      },
      request_id: "req-abc123"
    )
    artifact = identity.verify_artifact!(
      artifact: {
        "id" => 77, "name" => "hive-release-candidate-42-2",
        "expired" => false, "digest" => ARTIFACT_DIGEST,
        "workflow_run" => { "id" => 42, "head_sha" => WORKFLOW_SHA }
      },
      run_id: 42, run_attempt: 2
    )

    assert_equal 42, result.fetch("run_id")
    assert_equal 2, result.fetch("run_attempt")
    assert_equal 77, artifact.fetch("artifact_id")
    assert_equal ARTIFACT_DIGEST, artifact.fetch("artifact_digest")
  end

  def test_run_identity_rejects_another_request_repository_or_attempt
    run = {
      "id" => 42, "run_attempt" => 2, "name" => "hive-release-candidate:req-abc123:#{SHA}",
      "event" => "workflow_dispatch", "status" => "completed", "conclusion" => "success",
      "head_sha" => WORKFLOW_SHA, "head_branch" => "main",
      "path" => ".github/workflows/release-candidate.yml",
      "head_repository" => { "full_name" => "ivankuznetsov/hive" }
    }

    [
      ->(copy) { copy["name"] = "hive-release-candidate:req-other:#{SHA}" },
      ->(copy) { copy["run_attempt"] = 3 },
      ->(copy) { copy["head_repository"] = { "full_name" => "other/hive" } }
    ].each do |mutate|
      copy = Marshal.load(Marshal.dump(run))
      mutate.call(copy)
      assert_raises(HiveReleaseCandidate::Error) do
        identity.verify_run!(run: copy, request_id: "req-abc123", expected_attempt: 2)
      end
    end
  end

  private

  def identity
    HiveReleaseCandidate::RemoteIdentity.new(
      repository: "ivankuznetsov/hive",
      candidate_sha: SHA,
      workflow_sha: WORKFLOW_SHA,
      action_lock_sha256: ACTION_LOCK
    )
  end

  def valid_preflight
    {
      repository: { "full_name" => "ivankuznetsov/hive", "default_branch" => "main" },
      branch: { "name" => "main", "protected" => true },
      comparison: { "status" => "behind", "base_sha" => WORKFLOW_SHA, "head_sha" => SHA },
      workflow: {
        "path" => ".github/workflows/release-candidate.yml",
        "state" => "active",
        "revision" => WORKFLOW_SHA
      }
    }
  end
end
