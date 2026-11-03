# frozen_string_literal: true

require "support/bench_harness"
require "rejudge"
require "merge_results"
require "lib/generation_provenance"

class BenchHarnessRejudgeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("bench-backfill")
    @corpus = File.join(@root, "corpus")
    @entry_dir = File.join(@corpus, "t")
    FileUtils.mkdir_p(@entry_dir)
    File.write(File.join(@entry_dir, "plan.md"), "frozen plan")
    manifest = { "task_id" => "t", "source" => { "base_commit" => "base" }, "spec" => { "plan" => "plan.md" } }
    File.write(File.join(@entry_dir, "manifest.yml"), YAML.dump(manifest))
    @entry = manifest.merge("entry_dir" => @entry_dir)
    @runs = File.join(@root, "runs")
    @bundle = File.join(@runs, "t", "A")
    FileUtils.mkdir_p(@bundle)
    File.write(File.join(@bundle, "candidate.patch"), "+patch")
    @old = { "task_id" => "t", "agent_id" => "A", "run_status" => "generated", "mode" => "fresh",
             "subset" => "gated", "gate" => { "status" => "pass" },
             "judges" => { "X" => { "mean" => 2.0, "sample_count" => 3 } }, "efficiency" => { "cost_usd" => 3.0 } }
    @calls = []
    @judge = lambda do |**kwargs|
      @calls << kwargs
      HiveBench::Judge::Result.new(mean: 9.0, stddev: 0.0, scores: [9.0], interval: [9.0, 9.0], reference_withheld: true)
    end
  end

  def teardown = FileUtils.remove_entry(@root)

  def backfill(old = @old, dirs: [@runs], document: nil, judges: { "X" => @judge })
    HiveBench::Rejudge.run(document: document || { "cells" => [old] }, search_dirs: dirs, source: "unused",
                           corpus_root: @corpus, judges: judges, withhold_reference: true, only_missing_judges: true)
  end

  def bind_current
    manifest = HiveBench::GenerationProvenance.start!(out_dir: @bundle, entry: @entry, agent_id: "A", clear_artifacts: false)
    manifest = HiveBench::GenerationProvenance.finalize!(out_dir: @bundle, manifest: manifest,
                diff_path: File.join(@bundle, "candidate.patch"), plan: "frozen plan", status: "generated")
    @old.merge!(manifest.slice("generation_id", "artifact_binding"))
    @old["record_kind"] = "generation"
    @old["evaluation_context"] = HiveBench::GenerationProvenance.context(plan: "frozen plan", reference: nil, withheld: true)
    evidence = HiveBench::ResultEvidence.binding(@old)
    @old["gate"]["evidence_binding"] = evidence
    @old["judges"]["X"]["evidence_binding"] = evidence
  end

  def test_legacy_rejudging_adopts_artifacts_without_regeneration_or_old_judge_reuse
    out = backfill
    cell = out.fetch("cells").first
    assert_equal 1, @calls.size
    assert_equal 9.0, cell.dig("judges", "X", "mean")
    assert_equal "judge_only", cell.fetch("record_kind")
    refute_nil cell["generation_id"]
    assert_equal 1, out.fetch("generation_history").size
    assert_equal 1, out.dig("agents", "A", "judged", "scored_cells")
    assert_equal 0, out.dig("agents", "A", "gated", "total")
    assert_equal "gated", cell["subset"]
    assert out.fetch("rejudging_needed").first.fetch("reasons").include?("fresh gating required")
  end

  def test_unchanged_backfill_retains_original_judge_gate_subset_and_cost
    bind_current
    out = backfill(judges: { "X" => @judge, "Y" => @judge })
    assert_equal 1, @calls.size
    cell = out.fetch("cells").first
    assert_equal 2.0, cell.dig("judges", "X", "mean")
    assert_equal 9.0, cell.dig("judges", "Y", "mean")
    assert_equal @old["generation_id"], cell["generation_id"]
    assert_equal @old["gate"], cell["gate"]
    assert_equal 1, out.dig("agents", "A", "gated", "total")
    assert_equal 3.0, out.dig("agents", "A", "efficiency", "total_cost_usd")
  end

  def test_missing_and_ambiguous_artifacts_are_not_empty_diff_successes
    FileUtils.rm_f(File.join(@bundle, "candidate.patch"))
    missing = backfill
    assert_empty @calls
    assert_equal 0, missing.dig("agents", "A", "judged", "scored_cells")
    assert missing.fetch("rejudging_needed").first.fetch("reasons").any? { |r| r.include?("artifact") }
    File.write(File.join(@bundle, "candidate.patch"), "+patch")
    other = File.join(@root, "other")
    FileUtils.mkdir_p(File.join(other, "t"))
    FileUtils.cp_r(@bundle, File.join(other, "t", "A"))
    ambiguous = backfill(dirs: [@runs, other])
    assert_empty @calls
    assert ambiguous.fetch("rejudging_needed").first.fetch("reasons").any? { |r| r.include?("ambiguous") }
  end

  def test_wrong_generation_bundle_cannot_satisfy_only_missing
    bind_current
    @old["generation_id"] = "different-generation"
    out = backfill
    assert_empty @calls
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
  end

  def test_failed_status_partials_can_be_judged_only_as_diagnostics
    @old["run_status"] = "timed_out"
    out = backfill
    assert_equal 1, @calls.size
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
    assert_equal 1, out.dig("agents", "A", "diagnostics", "judged", "scored_cells")
    assert out.dig("agents", "A", "preliminary")
  end

  def test_rejudge_preserves_document_metadata_history_and_buckets_idempotently
    document = { "schema" => "old", "schema_version" => 1, "custom" => { "keep" => true },
                 "cells" => [@old], "pending" => [@old], "failed" => [], "generation_history" => [] }
    first = backfill(document: document)
    assert_equal 3.0, first.dig("agents", "A", "efficiency", "total_cost_usd")
    second = backfill(document: first)
    %w[schema schema_version custom pending failed].each { |key| assert_equal document[key], second[key] }
    assert_equal first.fetch("generation_history"), second.fetch("generation_history")
    assert_equal first.dig("agents", "A", "efficiency"), second.dig("agents", "A", "efficiency")
  end
end
