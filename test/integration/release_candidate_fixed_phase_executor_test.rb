require "test_helper"
require "digest"
require "json"
require_relative "../../packaging/release_candidate/baseline_catalog"
require_relative "../../packaging/release_candidate/installed_target"
require_relative "../../packaging/release_candidate/upgrade_survivor"

class ReleaseCandidateFixedPhaseExecutorTest < Minitest::Test
  include HiveTestHelper
  ROOT = File.expand_path("../..", __dir__).freeze
  CATALOG = File.join(ROOT, "packaging/release_candidate/baselines.yml").freeze
  FIXTURE = File.join(ROOT, "test/release_candidate/upgrade/fake-installed-hive").freeze

  def test_real_producer_contract_runs_v041_init_then_exact_legacy_install_then_task_creation
    with_tmp_dir do |dir|
      baseline = target(
        dir, "baseline", "0.4.1",
        "596f8e9018a2a7d419ca1758344ed64b617d1edb5679a25e8d86684ecb15ee36"
      )
      row = HiveReleaseCandidate::BaselineCatalog.load(CATALOG).fetch("legacy-bench-v041")
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedPhaseExecutor.new(
        process_teardown: HiveReleaseCandidate::ProcessTeardown.new
      )

      receipt = executor.call(
        target: baseline, phase: "before", row: row, run_root: File.join(dir, "run")
      )

      assert_equal "passed", receipt.fetch("status"), receipt.inspect
      assert_equal(
        [
          [ "init", File.join(dir, "run", "project") ],
          [ "new", "project", "legacy bench campaign", "--workflow", "bench", "--json" ]
        ],
        receipt.fetch("commands").map { |command| command.fetch("argv") }
      )
      state = File.join(dir, "run", "project", ".hive-state")
      assert_equal(
        HiveReleaseCandidate::UpgradeSurvivor::FixedPhaseExecutor::LEGACY_DESCRIPTOR,
        File.read(File.join(state, "workflows", "bench.yml"))
      )
      assert_equal(
        "Legacy local generate instructions.\n",
        File.read(File.join(state, "workflows", "bench", "generate.md"))
      )
      assert_equal(
        "legacy-campaign-260727-abcd",
        receipt.dig("snapshot", "tasks").keys.fetch(0)
      )
      assert_equal(
        [ "WAITING" ],
        receipt.dig("snapshot", "tasks", "legacy-campaign-260727-abcd", "markers")
      )
      assert_equal "directory", receipt.dig("snapshot", "durable_attempts", "status")
      assert_equal "directory", receipt.dig("snapshot", "dispatch_receipts", "status")
      assert_equal "directory", receipt.dig("snapshot", "managed_web_data", "status")
      assert_equal "directory", receipt.dig("snapshot", "service_definitions", "status")
      assert_equal "real-installed", receipt.fetch("producer_kind")
    end
  end

  def test_observer_executes_v042_role_and_requires_exact_collision
    with_tmp_dir do |dir|
      baseline = target(
        dir, "baseline", "0.4.1",
        "596f8e9018a2a7d419ca1758344ed64b617d1edb5679a25e8d86684ecb15ee36"
      )
      observer = target(
        dir, "observer", "0.4.2",
        "df7e1599621db2fe4710dcd676d11be6b7f0a8a050fcda3b28030e943143a356"
      )
      row = HiveReleaseCandidate::BaselineCatalog.load(CATALOG).fetch("legacy-bench-v041")
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedPhaseExecutor.new(
        process_teardown: HiveReleaseCandidate::ProcessTeardown.new
      )
      executor.call(target: baseline, phase: "before", row: row, run_root: File.join(dir, "run"))

      receipt = executor.call(
        target: observer, phase: "observer", row: row, run_root: File.join(dir, "run")
      )

      assert_equal "expected_failure_observed", receipt.fetch("status"), receipt.inspect
      assert_equal "legacy_workflow_collision", receipt.fetch("reason")
      assert_equal(
        { "outcome" => "expected_failure", "code" => "workflow_id_collision:bench" },
        receipt.fetch("observation")
      )
      assert_equal(
        [ "new", "project", "collision observer", "--workflow", "bench", "--json" ],
        receipt.dig("commands", 0, "argv")
      )
    end
  end

  private

  def target(dir, role, version, digest)
    root = File.join(dir, role)
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.cp(FIXTURE, File.join(root, "bin/hive"))
    File.chmod(0o755, File.join(root, "bin/hive"))
    File.write(File.join(root, "target.json"), JSON.generate(
      "schema" => "hive-release-candidate-installed-target",
      "schema_version" => 1, "role" => role, "version" => version,
      "gem_sha256" => digest, "executable" => "bin/hive",
      "skills" => { "archive_sha256" => "c" * 64, "import_root" => "skills" }
    ))
    HiveReleaseCandidate::InstalledTarget.new(
      role: role, root: root, state_root: File.join(dir, "state")
    )
  end
end
