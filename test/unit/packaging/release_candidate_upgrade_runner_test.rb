require "test_helper"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateUpgradeRunnerTest < Minitest::Test
  SHA = "a" * 40

  def test_runner_executes_both_upgrade_gates_only_after_cache_and_sandbox_preflight
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
    runner = HiveReleaseCandidate::Runner.new(
      repo_root: File.expand_path("../../..", __dir__),
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
      result = runner.send(
        :execute_gate, runner.registry.fetch(name),
        artifacts: artifacts, inputs: {}, manifest: manifest,
        baseline_cache: cache
      )
      assert_equal "passed", result.fetch("status")
      assert result.dig("details", "producer_started")
    end
    assert_equal %w[latest-stable legacy-bench-v041], rows

    missing = runner.send(
      :execute_gate, runner.registry.fetch("latest_stable_upgrade"),
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

  def test_runner_does_not_claim_sandbox_availability_without_a_local_executor
    sandbox = Object.new
    sandbox.define_singleton_method(:capability) do |**|
      raise "sandbox must not be probed without an executable local lane"
    end
    runner = HiveReleaseCandidate::Runner.new(
      repo_root: File.expand_path("../../..", __dir__),
      sandbox: sandbox
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

    result = runner.send(
      :execute_gate, runner.registry.fetch("latest_stable_upgrade"),
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
    runner = HiveReleaseCandidate::Runner.new(
      repo_root: File.expand_path("../../..", __dir__)
    )
    gate = runner.registry.fetch("candidate_version")
    artifacts = Struct.new(:candidate_dir).new("/candidate")
    cache = { "status" => "available" }

    passed = runner.send(
      :execute_gate, gate,
      artifacts: artifacts,
      inputs: { "baselines" => { "latest_stable_version" => "0.6.9" } },
      manifest: { "hive_version" => "0.7.0" },
      baseline_cache: cache
    )
    unavailable = runner.send(
      :execute_gate, gate,
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
    runner = HiveReleaseCandidate::Runner.new(
      repo_root: File.expand_path("../../..", __dir__)
    )
    source = {
      "effective_gate_set" => [
        { "name" => "artifact_integrity", "status" => "passed" },
        { "name" => "coverage_catalog", "status" => "failed" },
        { "name" => "baseline_catalog", "status" => "unavailable" },
        { "name" => "latest_stable_upgrade", "status" => "pending" }
      ]
    }

    selected = runner.send(:missing_for_resume, source).map(&:name)

    assert_includes selected, "latest_stable_upgrade"
    assert_includes selected, "legacy_bench_v041_upgrade"
    refute_includes selected, "artifact_integrity"
    refute_includes selected, "coverage_catalog"
    refute_includes selected, "baseline_catalog"
  end
end
