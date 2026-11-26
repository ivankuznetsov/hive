# frozen_string_literal: true

require "support/bench_harness"
require "run"
require "run_all"
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

  def test_run_all_rescue_sets_verification_error_and_preserves_judged_subset
    corrupting_runner = lambda do |entry:, profile:, out_dir:|
      cell = HiveBench::Run.new(restorer: @restorer, spawn: ->(**) { { status: :ok, usage: { cost: 1.0 }, stdout: "", stderr: "" } })
                           .call(entry: entry, profile: profile, out_dir: out_dir)
      File.write(cell.diff_path, "+tampered after finalize\n")
      cell
    end
    gate = Object.new
    def gate.call(**) = flunk("gate must not run on unverified artifact")
    outcome = nil
    capture_io do
      outcome = HiveBench::RunAll.new(runner: corrupting_runner, gate: gate, judges: {}, withhold_reference: true)
                                 .call(entries: [ @entry ], profiles: [ @profile ], out_root: @out, corpus_version: "v2")
    end
    assert_equal 1, outcome.failed.size
    record = outcome.results.fetch("cells").first
    refute_nil record["artifact_verification_error"]
    refute HiveBench::ResultEvidence.bound_generation?(record)
    assert_equal "judged", record["subset"]
    assert_equal 0, outcome.results.dig("agents", "A", "diagnostics", "gated", "total")
    reasons = outcome.results.fetch("rejudging_needed").first.fetch("reasons")
    assert reasons.any? { |reason| reason.include?("artifact recovery/rejudging required") }
    refute_includes reasons, "fresh gating required"
  end

  def test_run_all_rescue_before_start_does_not_stamp_prior_manifest_onto_failed_record
    cell_out = File.join(@out, @entry["task_id"], @profile.id)
    prior = HiveBench::GenerationProvenance.start!(out_dir: cell_out, entry: @entry, agent_id: @profile.id)
    File.write(File.join(cell_out, "candidate.patch"), "+prior\n")
    prior = HiveBench::GenerationProvenance.finalize!(
      out_dir: cell_out, manifest: prior, diff_path: File.join(cell_out, "candidate.patch"),
      plan: "plan", status: "generated", telemetry: { "cost_usd" => 7.0 }
    )
    failing_before_start = lambda do |**|
      raise "ArtifactProvenanceMismatch before start!"
    end
    outcome = nil
    capture_io do
      outcome = HiveBench::RunAll.new(runner: failing_before_start, gate: Object.new, judges: {}, withhold_reference: true)
                                 .call(entries: [ @entry ], profiles: [ @profile ], out_root: @out, corpus_version: "v2")
    end
    assert_equal 1, outcome.failed.size
    parked = outcome.failed.first
    refute_equal prior["generation_id"], parked["generation_id"]
    assert_nil parked["generation_id"]
    assert_nil parked["run_status"]
    assert_equal({}, parked["efficiency"])
  end
end
