require "test_helper"
require "json_schemer"
require_relative "../../../packaging/release_candidate/evidence"

class ReleaseCandidateEvidenceTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  DIGEST = "b" * 64

  def test_attempts_are_append_only_and_effective_gates_reference_predecessor_results
    with_evidence_fixture do |evidence, identity, paths|
      first = evidence.write_attempt(
        identity: identity,
        selected_gates: [ "artifact_integrity" ],
        gate_results: [ gate("artifact_integrity", "passed") ],
        candidate_version: "0.6.9",
        baseline_version: "0.6.9"
      )
      first_path = paths.evidence_path(first.fetch("attempt_id"))
      first_bytes = File.binread(first_path)

      second = evidence.write_attempt(
        identity: identity,
        selected_gates: [ "coverage_catalog" ],
        gate_results: [ gate("coverage_catalog", "failed", "catalog_mismatch") ],
        predecessor: first,
        selection_mode: "rerun_named",
        candidate_version: "0.6.9",
        baseline_version: "0.6.9"
      )

      assert_equal first_bytes, File.binread(first_path)
      assert_equal first.fetch("attempt_id"),
                   second.fetch("predecessor_attempt_id")
      effective = second.fetch("effective_gate_set").to_h do |entry|
        [ entry.fetch("name"), entry ]
      end
      assert_equal first.fetch("attempt_id"),
                   effective.fetch("artifact_integrity").fetch("attempt_id")
      assert_equal second.fetch("attempt_id"),
                   effective.fetch("coverage_catalog").fetch("attempt_id")
      assert_includes second.fetch("blockers"), "catalog_mismatch"
      assert_includes second.fetch("blockers"), "candidate_not_newer"
    end
  end

  def test_interruption_records_atomic_partial_without_claiming_local_success
    with_evidence_fixture do |evidence, identity, _paths|
      attempt = evidence.write_attempt(
        identity: identity,
        selected_gates: %w[artifact_integrity coverage_catalog],
        gate_results: [
          gate("artifact_integrity", "running", "interrupted"),
          gate("coverage_catalog", "pending", "interrupted_before_start")
        ],
        interrupted: true,
        candidate_version: "0.7.0",
        baseline_version: "0.6.9"
      )

      assert_equal "partial", attempt.fetch("scope_status")
      assert_equal "partial", attempt.fetch("qa_status")
      assert_equal attempt, evidence.load(attempt.fetch("attempt_id"))
    end
  end

  def test_resume_identity_drift_and_selected_gate_result_mismatch_fail_closed
    with_evidence_fixture do |evidence, identity, _paths|
      source = evidence.write_attempt(
        identity: identity,
        selected_gates: [ "artifact_integrity" ],
        gate_results: [ gate("artifact_integrity", "passed") ],
        candidate_version: "0.7.0",
        baseline_version: "0.6.9"
      )

      drifted = identity.merge("tool" => "c" * 64)
      drifted["fingerprint"] = Digest::SHA256.hexdigest(
        JSON.generate(drifted.reject { |key, _value| key == "fingerprint" }.sort.to_h)
      )
      error = assert_raises(HiveReleaseCandidate::Error) do
        evidence.verify_resume_identity!(source, drifted)
      end
      assert_includes error.message, "stale"

      cache_drifted = identity.merge("baseline_cache" => "d" * 64)
      cache_drifted["fingerprint"] = Digest::SHA256.hexdigest(
        JSON.generate(cache_drifted.reject { |key, _value| key == "fingerprint" }.sort.to_h)
      )
      error = assert_raises(HiveReleaseCandidate::Error) do
        evidence.verify_resume_identity!(source, cache_drifted)
      end
      assert_includes error.message, "stale"

      error = assert_raises(HiveReleaseCandidate::Error) do
        evidence.write_attempt(
          identity: identity,
          selected_gates: [ "artifact_integrity" ],
          gate_results: [ gate("coverage_catalog", "passed") ],
          candidate_version: "0.7.0",
          baseline_version: "0.6.9"
        )
      end
      assert_includes error.message, "exactly"
    end
  end

  def test_failed_rerun_selection_uses_the_effective_gate_set
    registry = HiveReleaseCandidate::GateRegistry.new
    source = {
      "gates" => [ gate("coverage_catalog", "passed") ],
      "effective_gate_set" => [
        { "name" => "artifact_integrity", "status" => "failed", "attempt_id" => "old" },
        { "name" => "coverage_catalog", "status" => "passed", "attempt_id" => "new" }
      ]
    }

    assert_equal [ "artifact_integrity" ],
                 registry.rerun(source: source, mode: "failed").map(&:name)
  end

  def test_written_attempt_matches_the_published_evidence_schema
    with_evidence_fixture do |evidence, identity, _paths|
      attempt = evidence.write_attempt(
        identity: identity,
        selected_gates: [ "artifact_integrity" ],
        gate_results: [ gate("artifact_integrity", "passed") ],
        candidate_version: "0.7.0",
        baseline_version: "0.6.9"
      )
      schema_path = File.expand_path(
        "../../../schemas/hive-release-candidate-evidence.v1.json",
        __dir__
      )
      schemer = JSONSchemer.schema(JSON.parse(File.read(schema_path)))
      errors = schemer.validate(attempt).to_a

      assert_empty errors, errors.inspect
    end
  end

  def test_unavailable_baseline_is_null_without_a_false_version_blocker
    with_evidence_fixture do |evidence, identity, _paths|
      attempt = evidence.write_attempt(
        identity: identity,
        selected_gates: [ "artifact_integrity" ],
        gate_results: [ gate("artifact_integrity", "unavailable", "baseline_catalog_unavailable") ],
        candidate_version: "0.7.0",
        baseline_version: nil
      )

      assert_nil attempt.fetch("baseline_version")
      refute_includes attempt.fetch("blockers"), "candidate_not_newer"
      assert_includes attempt.fetch("blockers"), "baseline_catalog_unavailable"
      schema_path = File.expand_path(
        "../../../schemas/hive-release-candidate-evidence.v1.json", __dir__
      )
      assert_empty JSONSchemer.schema(JSON.parse(File.read(schema_path))).
        validate(attempt).to_a
    end
  end

  private

  def gate(name, status, reason = nil)
    { "name" => name, "status" => status, "reason" => reason }
  end

  def with_evidence_fixture
    with_tmp_dir do |repo|
      paths = HiveReleaseCandidate::Paths.new(repo_root: repo, candidate_sha: SHA)
      paths.prepare!
      FileUtils.mkdir_p(paths.candidate_dir)
      manifest = {
        "schema" => "fixture",
        "schema_version" => 1,
        "files" => {}
      }
      File.write(paths.manifest_path, JSON.generate(manifest))
      FileUtils.mkdir_p(paths.inputs_dir)
      File.write(
        File.join(paths.inputs_dir, "coverage.json"),
        JSON.generate("schema" => "coverage", "sha256" => DIGEST)
      )
      File.write(
        File.join(paths.inputs_dir, "baselines.json"),
        JSON.generate(
          "schema" => "baselines", "sha256" => DIGEST,
          "catalog_dependency_closure_sha256" => DIGEST
        )
      )
      inputs = %w[coverage baselines action_lock workflow tool schema].to_h do |name|
        [ name, { "sha256" => DIGEST } ]
      end
      inputs.fetch("baselines")["catalog_dependency_closure_sha256"] = DIGEST
      evidence = HiveReleaseCandidate::Evidence.new(paths: paths)
      baseline_cache = {
        "status" => "available",
        "release_assets_sha256" => "a" * 64,
        "verified_dependency_closure_sha256" => "b" * 64
      }
      identity = evidence.identity(
        candidate_manifest: paths.manifest_path, inputs: inputs,
        baseline_cache: baseline_cache
      )
      assert_equal DIGEST, identity.fetch("baseline_dependency_closure")
      assert_match(/\A[0-9a-f]{64}\z/, identity.fetch("baseline_cache"))

      yield evidence, identity, paths
    end
  end
end
