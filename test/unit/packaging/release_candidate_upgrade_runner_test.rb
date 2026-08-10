require "test_helper"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateUpgradeRunnerTest < Minitest::Test
  SHA = "a" * 40

  def test_gate_execution_runs_both_upgrade_gates_only_after_cache_and_sandbox_preflight
    rows = []
    upgrade = lambda do |row_id:, candidate_manifest:, **|
      rows << row_id
      assert_equal SHA, candidate_manifest.fetch("candidate_sha")
      { "status" => "passed", "reason" => nil, "row_id" => row_id }
    end
    sandbox = Object.new
    sandbox.define_singleton_method(:capability) do |candidate_sha:|
      {
        "status" => "available", "kind" => "container",
        "network_after_staging" => "none", "candidate_sha" => candidate_sha
      }
    end
    registry = HiveReleaseCandidate::GateRegistry.new
    execution = HiveReleaseCandidate::GateExecution.new(
      upgrade_executor: upgrade, sandbox: sandbox
    )
    manifest = {
      "candidate_sha" => SHA, "hive_version" => "0.6.9",
      "files" => {
        "hive-cli-0.6.9.gem" => {
          "kind" => "gem", "sha256" => "b" * 64, "size" => 4
        }
      }
    }
    cache = {
      "status" => "available", "release_assets_sha256" => "c" * 64,
      "verified_dependency_closure_sha256" => "d" * 64
    }
    artifacts = Struct.new(:candidate_dir).new("/candidate")

    %w[latest_stable_upgrade legacy_bench_v041_upgrade].each do |name|
      result = execution.call(
        registry.fetch(name),
        artifacts: artifacts, inputs: {}, manifest: manifest,
        baseline_cache: cache
      )
      assert_equal "passed", result.fetch("status")
      assert result.dig("details", "producer_started")
    end
    assert_equal %w[latest-stable legacy-bench-v041], rows

    missing = execution.call(
      registry.fetch("latest_stable_upgrade"),
      artifacts: artifacts, inputs: {}, manifest: manifest,
      baseline_cache: { "status" => "missing", "reason" => "baseline_assets_missing" }
    )
    assert_equal "unavailable", missing.fetch("status")
    refute missing.dig("details", "producer_started")
    assert_equal(
      [ "bin/hive-release-candidate", "dispatch", "--sha", SHA ],
      missing.dig("details", "next_action_argv")
    )
    assert_equal 2, rows.size, "missing cache must not invoke the producer"
  end

  def test_gate_execution_does_not_claim_sandbox_availability_without_a_local_executor
    sandbox = Object.new
    sandbox.define_singleton_method(:capability) do |**|
      raise "sandbox must not be probed without an executable local lane"
    end
    registry = HiveReleaseCandidate::GateRegistry.new
    execution = HiveReleaseCandidate::GateExecution.new(sandbox: sandbox)
    manifest = {
      "candidate_sha" => SHA, "hive_version" => "0.6.9",
      "files" => {
        "hive-cli-0.6.9.gem" => {
          "kind" => "gem", "sha256" => "b" * 64, "size" => 4
        }
      }
    }
    cache = {
      "status" => "available", "release_assets_sha256" => "c" * 64,
      "verified_dependency_closure_sha256" => "d" * 64
    }
    artifacts = Struct.new(:candidate_dir).new("/candidate")

    result = execution.call(
      registry.fetch("latest_stable_upgrade"),
      artifacts: artifacts, inputs: {}, manifest: manifest,
      baseline_cache: cache
    )

    assert_equal "unavailable", result.fetch("status")
    assert_equal "compliant_local_upgrade_executor_unavailable", result.fetch("reason")
    refute result.dig("details", "producer_started")
    assert_equal(
      [ "bin/hive-release-candidate", "dispatch", "--sha", SHA ],
      result.dig("details", "next_action_argv")
    )
  end

  def test_candidate_version_gate_uses_the_reviewed_catalog_input
    registry = HiveReleaseCandidate::GateRegistry.new
    execution = HiveReleaseCandidate::GateExecution.new
    gate = registry.fetch("candidate_version")
    artifacts = Struct.new(:candidate_dir).new("/candidate")
    cache = { "status" => "available" }

    passed = execution.call(
      gate,
      artifacts: artifacts,
      inputs: { "baselines" => { "latest_stable_version" => "0.6.9" } },
      manifest: { "hive_version" => "0.7.0" },
      baseline_cache: cache
    )
    unavailable = execution.call(
      gate,
      artifacts: artifacts,
      inputs: { "baselines" => { "status" => "unavailable" } },
      manifest: { "hive_version" => "0.7.0" },
      baseline_cache: cache
    )

    assert_equal "passed", passed.fetch("status")
    assert_equal "unavailable", unavailable.fetch("status")
    assert_equal "baseline_catalog_unavailable", unavailable.fetch("reason")
  end

  def test_resume_selects_only_incomplete_or_absent_default_gates
    repo_root = File.expand_path("../../..", __dir__)
    repository = HiveReleaseCandidate::Repository.new(repo_root)
    registry = HiveReleaseCandidate::GateRegistry.new
    attempt = HiveReleaseCandidate::LocalAttempt.new(
      repo_root: repo_root, runs_root: nil, repository: repository, registry: registry,
      baseline_cache: HiveReleaseCandidate::BaselineCache.new(
        repo_root: repo_root, repository: repository
      ),
      gate_execution: HiveReleaseCandidate::GateExecution.new
    )
    source = {
      "effective_gate_set" => [
        { "name" => "artifact_integrity", "status" => "passed" },
        { "name" => "coverage_catalog", "status" => "failed" },
        { "name" => "baseline_catalog", "status" => "unavailable" },
        { "name" => "latest_stable_upgrade", "status" => "pending" }
      ]
    }

    selected = attempt.send(:missing_for_resume, source).map(&:name)

    assert_includes selected, "latest_stable_upgrade"
    assert_includes selected, "legacy_bench_v041_upgrade"
    refute_includes selected, "artifact_integrity"
    refute_includes selected, "coverage_catalog"
    refute_includes selected, "baseline_catalog"
  end
end
