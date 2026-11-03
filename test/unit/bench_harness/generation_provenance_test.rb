# frozen_string_literal: true

require "support/bench_harness"
require "run"
require "lib/generation_provenance"

class BenchHarnessGenerationProvenanceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("bench-provenance")
    File.write(File.join(@root, "plan.md"), "plan")
    @entry = { "task_id" => "t", "source" => { "base_commit" => "base" },
               "checkout_source" => "unused", "entry_dir" => @root, "spec" => { "plan" => "plan.md" } }
    @profile = Struct.new(:id, :model).new("A", "model")
    @out = File.join(@root, "out")
    @restorer = Object.new
    def @restorer.restore(source:, base_commit:, into:) = FileUtils.mkdir_p(into)
    def @restorer.diff(work_dir:, base_commit:) = "+same bytes\n"
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_candidate(status = :ok)
    spawn = lambda do |**|
      attempt = JSON.parse(File.read(File.join(@out, "generation-attempt.json")))
      assert_equal "started", attempt.fetch("state")
      assert_nil attempt["artifact_binding"]
      { status: status, usage: { cost: 1.0 }, stdout: "", stderr: "" }
    end
    HiveBench::Run.new(restorer: @restorer, spawn: spawn).call(entry: @entry, profile: @profile, out_dir: @out)
  end

  def test_identical_regeneration_rotates_attempt_identity_before_spawn
    first = run_candidate
    second = run_candidate
    refute_equal first.generation_id, second.generation_id
    assert_equal first.artifact_binding, second.artifact_binding
    manifest = HiveBench::GenerationProvenance.load(@out)
    assert_equal second.generation_id, manifest.fetch("generation_id")
    assert_equal "generated", manifest.fetch("run_status")
    assert_equal "finalized", manifest.fetch("state")
  end

  def test_success_to_failure_cannot_reuse_stale_patch
    first = run_candidate
    failing = HiveBench::Run.new(restorer: @restorer, spawn: ->(**) { raise "before patch" })
    assert_raises(RuntimeError) { failing.call(entry: @entry, profile: @profile, out_dir: @out) }
    manifest = HiveBench::GenerationProvenance.load(@out)
    refute_equal first.generation_id, manifest.fetch("generation_id")
    refute_path_exists File.join(@out, "candidate.patch")
    assert_nil manifest["artifact_binding"]
  end

  def test_manifest_integrity_rejects_changed_artifact
    run_candidate
    File.write(File.join(@out, "candidate.patch"), "+forged")
    assert_raises(HiveBench::GenerationProvenance::Mismatch) do
      HiveBench::GenerationProvenance.verify!(@out, entry: @entry, agent_id: "A")
    end
  end

  def test_timeout_keeps_attempt_telemetry_and_binding_for_diagnostics
    cell = run_candidate(:timeout)
    assert_equal "timed_out", cell.status
    assert_equal 1.0, cell.telemetry.fetch("cost_usd")
    refute_nil cell.generation_id
    refute_nil cell.artifact_binding
  end
end
