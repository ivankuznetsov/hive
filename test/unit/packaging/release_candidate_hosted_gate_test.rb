require "test_helper"
require "digest"
require "json"
require_relative "../../../packaging/release_candidate/hosted_gate"

class ReleaseCandidateHostedGateTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ACTION_LOCK = "c" * 64
  ARTIFACT_DIGEST = "sha256:#{'d' * 64}"

  def test_receipt_binds_exact_remote_producer_and_manifest_filenames
    with_tmp_dir do |dir|
      build_candidate(dir)
      receipt = gate.call(
        name: "Catalog integrity", repository: "ivankuznetsov/hive",
        candidate_sha: SHA, workflow_sha: WORKFLOW_SHA, run_id: 52,
        run_attempt: 3, producer_run_id: 42, producer_run_attempt: 2,
        action_lock_sha256: ACTION_LOCK, artifact_id: 77,
        artifact_digest: ARTIFACT_DIGEST, request_id: "req-current",
        candidate_dir: dir, run_payload: producer_run,
        artifact_payload: artifact
      )

      assert_equal "hive-release-candidate-gate-receipt", receipt.fetch("schema")
      assert_equal 52, receipt.fetch("run_id")
      assert_equal 42, receipt.fetch("producer_run_id")
      assert_equal "req-producer", receipt.fetch("producer_request_id")
      assert_equal expected_names.sort, receipt.fetch("manifest_filenames").sort
    end
  end

  def test_rejects_wrong_run_name_artifact_or_manifest_filename
    with_tmp_dir do |dir|
      build_candidate(dir)
      wrong_run = producer_run.merge(
        "display_title" => "hive-release-candidate:req-producer:#{"e" * 40}"
      )
      assert_raises(HiveReleaseCandidate::Error) do
        invoke(dir, run_payload: wrong_run, artifact_payload: artifact)
      end

      wrong_artifact = artifact.merge("digest" => "sha256:#{'e' * 64}")
      assert_raises(HiveReleaseCandidate::Error) do
        invoke(dir, run_payload: producer_run, artifact_payload: wrong_artifact)
      end

      File.rename(
        File.join(dir, expected_names.first),
        File.join(dir, "substituted.gem")
      )
      assert_raises(HiveReleaseCandidate::Error) do
        invoke(dir, run_payload: producer_run, artifact_payload: artifact)
      end
    end
  end

  private

  def gate
    HiveReleaseCandidate::HostedGate.new
  end

  def invoke(dir, run_payload:, artifact_payload:)
    gate.call(
      name: "Catalog integrity", repository: "ivankuznetsov/hive",
      candidate_sha: SHA, workflow_sha: WORKFLOW_SHA, run_id: 52,
      run_attempt: 3, producer_run_id: 42, producer_run_attempt: 2,
      action_lock_sha256: ACTION_LOCK, artifact_id: 77,
      artifact_digest: ARTIFACT_DIGEST, request_id: "req-current",
      candidate_dir: dir, run_payload: run_payload,
      artifact_payload: artifact_payload
    )
  end

  def build_candidate(dir)
    rows = expected_names.to_h do |name|
      body = "bytes for #{name}"
      File.binwrite(File.join(dir, name), body)
      kind = if name.end_with?(".gem")
               "gem"
      elsif name.include?("source")
               "source"
      elsif name.include?("skills")
               "skills"
      else
               "web"
      end
      [
        name,
        {
          "kind" => kind,
          "sha256" => Digest::SHA256.hexdigest(body),
          "size" => body.bytesize
        }
      ]
    end
    File.write(File.join(dir, "manifest.json"), JSON.generate(
      "schema" => "hive-release-candidate-artifacts",
      "schema_version" => 1,
      "candidate_sha" => SHA,
      "hive_version" => "0.7.0",
      "skill_version" => "1.0.0",
      "canonical_digest" => "e" * 64,
      "builder_revision" => "f" * 64,
      "files" => rows
    ))
  end

  def expected_names
    [
      "hive-cli-0.7.0.gem",
      "hive-source-#{SHA}.tar.gz",
      "hive-agent-skills-#{SHA}.tar.gz",
      "hive-web-0.7.0.tar.gz"
    ]
  end

  def producer_run
    {
      "id" => 42,
      "run_attempt" => 2,
      "name" => "Release candidate",
      "display_title" => "hive-release-candidate:req-producer:#{SHA}",
      "event" => "workflow_dispatch",
      "head_sha" => WORKFLOW_SHA,
      "head_branch" => "main",
      "path" => ".github/workflows/release-candidate.yml",
      "head_repository" => { "full_name" => "ivankuznetsov/hive" }
    }
  end

  def artifact
    {
      "id" => 77,
      "name" => "hive-release-candidate-42-2",
      "expired" => false,
      "digest" => ARTIFACT_DIGEST,
      "workflow_run" => { "id" => 42, "head_sha" => WORKFLOW_SHA }
    }
  end
end
