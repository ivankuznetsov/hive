# frozen_string_literal: true

require "support/bench_harness"
require "rejudge"
require "run_all"
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
      HiveBench::Judge::Result.new(mean: 9.0, stddev: 0.0, scores: [ 9.0 ], interval: [ 9.0, 9.0 ], reference_withheld: true)
    end
  end

  def teardown = FileUtils.remove_entry(@root)

  def backfill(old = @old, dirs: [ @runs ], document: nil, judges: { "X" => @judge })
    HiveBench::Rejudge.run(document: document || { "cells" => [ old ] }, search_dirs: dirs, source: "unused",
                           corpus_root: @corpus, judges: judges, withhold_reference: true, only_missing_judges: true)
  end

  def bind_current
    manifest = HiveBench::GenerationProvenance.start!(out_dir: @bundle, entry: @entry, agent_id: "A", clear_artifacts: false)
    manifest = HiveBench::GenerationProvenance.finalize!(out_dir: @bundle, manifest: manifest,
                diff_path: File.join(@bundle, "candidate.patch"), plan: "frozen plan", status: "generated")
    @old.merge!(manifest.slice("generation_id", "artifact_binding"))
    @old["record_kind"] = "generation"
    @old["evaluation_context"] = HiveBench::GenerationProvenance.context(plan: "frozen plan", reference: nil, withheld: true)
    @old["gate"]["evidence_binding"] = HiveBench::ResultEvidence.gate_binding(@old)
    @old["judges"]["X"]["evidence_binding"] = HiveBench::ResultEvidence.binding(@old)
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
    ambiguous = backfill(dirs: [ @runs, other ])
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
                 "cells" => [ @old ], "pending" => [ @old ], "failed" => [], "generation_history" => [] }
    first = backfill(document: document)
    assert_equal 3.0, first.dig("agents", "A", "efficiency", "total_cost_usd")
    second = backfill(document: first)
    %w[schema schema_version custom pending failed].each { |key| assert_equal document[key], second[key] }
    assert_equal first.fetch("generation_history"), second.fetch("generation_history")
    assert_equal first.dig("agents", "A", "efficiency"), second.dig("agents", "A", "efficiency")
  end

  def test_legacy_adoption_deduplicates_run_all_park_shape_without_dropping_distinct_failures
    parked_same = { "task_id" => "t", "agent_id" => "A", "reason" => "all judges failed",
                    "generation_id" => nil, "run_status" => "generated", "mode" => "fresh",
                    "efficiency" => { "cost_usd" => 3.0 } }
    parked_other = { "task_id" => "t", "agent_id" => "A", "reason" => "quota hit",
                     "generation_id" => nil, "run_status" => "limit_hit", "mode" => "fresh",
                     "efficiency" => { "cost_usd" => 1.5 } }
    document = { "cells" => [ @old ], "pending" => [ parked_same, parked_other ], "failed" => [], "generation_history" => [] }
    first = backfill(document: document)
    assert_equal 4.5, first.dig("agents", "A", "efficiency", "total_cost_usd")
    assert_equal 1, first.dig("agents", "A", "generation", "limit_hit")
    assert_equal 1, first.dig("agents", "A", "generation", "generated")
    second = backfill(document: first)
    assert_equal 4.5, second.dig("agents", "A", "efficiency", "total_cost_usd")
  end

  def test_legacy_rejudge_adopts_failed_finalized_manifest_without_ranking
    manifest = HiveBench::GenerationProvenance.start!(out_dir: @bundle, entry: @entry, agent_id: "A", clear_artifacts: false)
    HiveBench::GenerationProvenance.finalize!(
      out_dir: @bundle, manifest: manifest, diff_path: File.join(@bundle, "candidate.patch"),
      plan: "frozen plan", status: "timed_out", telemetry: { "cost_usd" => 0.75 }
    )
    out = backfill
    cell = out.fetch("cells").first
    assert_equal "timed_out", cell["run_status"]
    assert_equal({ "cost_usd" => 0.75 }, cell["efficiency"])
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
    assert_equal 1, out.dig("agents", "A", "diagnostics", "judged", "scored_cells")
    assert out.dig("agents", "A", "preliminary")
    assert_equal 0.75, out.dig("agents", "A", "efficiency", "total_cost_usd")
    assert_equal 1, out.fetch("generation_history").size
  end

  def test_identified_rejudge_rejects_manifest_run_status_conflict
    manifest = HiveBench::GenerationProvenance.start!(out_dir: @bundle, entry: @entry, agent_id: "A", clear_artifacts: false)
    manifest = HiveBench::GenerationProvenance.finalize!(
      out_dir: @bundle, manifest: manifest, diff_path: File.join(@bundle, "candidate.patch"),
      plan: "frozen plan", status: "agent_failed", telemetry: { "cost_usd" => 1.0 }
    )
    @old.merge!(manifest.slice("generation_id", "artifact_binding"))
    @old["record_kind"] = "generation"
    @old["run_status"] = "generated"
    out = backfill
    assert_empty @calls
    cell = out.fetch("cells").first
    assert_includes cell["artifact_verification_error"], "run_status conflict"
    assert_equal 0, out.dig("agents", "A", "judged", "scored_cells")
    assert out.fetch("rejudging_needed").first.fetch("reasons").any? { |r| r.include?("run_status conflict") }
  end

  def test_rejudge_with_changed_context_preserves_valid_current_generation_gate
    bind_current
    File.write(File.join(@entry_dir, "reference.patch"), "+gold\n")
    out = HiveBench::Rejudge.run(
      document: { "cells" => [ @old ] }, search_dirs: [ @runs ], source: "unused",
      corpus_root: @corpus, judges: { "X" => @judge },
      withhold_reference: false, only_missing_judges: true, plan_source: :candidate
    )
    cell = out.fetch("cells").first
    assert HiveBench::ResultEvidence.admitted_gate?(cell)
    assert_equal 1, out.dig("agents", "A", "gated", "total")
    assert_equal 1.0, out.dig("agents", "A", "gated", "pass_rate")
    reasons = out.fetch("rejudging_needed").flat_map { |item| item.fetch("reasons") }
    refute_includes reasons, "fresh gating required"
  end

  def test_run_all_candidate_plan_source_matches_rejudge_only_missing_without_rebuying
    v3_corpus = File.join(@root, "v3_corpus")
    v3_entry_dir = File.join(v3_corpus, "v3-task")
    FileUtils.mkdir_p(File.join(v3_entry_dir, "spec"))
    File.write(File.join(v3_entry_dir, "spec", "idea.md"), "idea\n")
    File.write(File.join(v3_entry_dir, "spec", "brainstorm.md"), "brainstorm\n")
    File.write(File.join(v3_entry_dir, "reference.patch"), "+gold\n")
    manifest = {
      "task_id" => "v3-task",
      "source" => { "base_commit" => "base" },
      "spec" => { "idea" => "spec/idea.md", "brainstorm" => "spec/brainstorm.md" }
    }
    File.write(File.join(v3_entry_dir, "manifest.yml"), YAML.dump(manifest))
    entry = manifest.merge("entry_dir" => v3_entry_dir)
    profile = Struct.new(:id, :model).new("A", "model")
    out_root = File.join(@root, "v3_runs")

    candidate_plan_text = "# Candidate generated plan\n1. Fix thing\n"
    runner = lambda do |entry:, profile:, out_dir:|
      attempt = HiveBench::GenerationProvenance.start!(out_dir: out_dir, entry: entry, agent_id: profile.id)
      plan_dir = File.join(out_dir, "target", ".hive-state", "stages", "3-plan", entry["task_id"])
      FileUtils.mkdir_p(plan_dir)
      File.write(File.join(plan_dir, "plan.md"), candidate_plan_text)
      patch_path = File.join(out_dir, "target", "candidate.patch")
      File.write(patch_path, "+candidate change\n")
      cell = HiveBench::Run::Cell.new(
        task_id: entry["task_id"], agent_id: profile.id, mode: "hive", model_version: "m",
        status: "generated", diff_path: patch_path, telemetry: { "cost_usd" => 2.0 }, reason: nil
      )
      HiveBench::GenerationProvenance.finalize_cell!(cell, out_dir: out_dir, manifest: attempt, plan: candidate_plan_text)
    end

    inline_plans = []
    judge_x = HiveBench::Judge.new(judge_fn: lambda do |prompt:, seed:|
      inline_plans << prompt
      { score: 8.5, reason: "inline-#{seed}" }
    end, seeds: 1)
    gate = Object.new
    def gate.call(**) = HiveBench::Gate::Result.new(status: :no_gate, subset: "judged", reason: "v3", details: {})

    outcome = HiveBench::RunAll.new(
      runner: runner, gate: gate, judges: { "X" => judge_x },
      withhold_reference: false, plan_source: :candidate
    ).call(entries: [ entry ], profiles: [ profile ], out_root: out_root, corpus_version: "v3")

    assert_equal 1, inline_plans.size
    assert_includes inline_plans.first, candidate_plan_text
    cell = outcome.results.fetch("cells").first
    assert_equal HiveBench::GenerationProvenance.digest(candidate_plan_text),
                 cell.dig("evaluation_context", "plan_sha256")

    x_rejudge_calls = 0
    y_rejudge_calls = 0
    rejudged = HiveBench::Rejudge.run(
      document: outcome.results, search_dirs: [ out_root ], source: "unused",
      corpus_root: v3_corpus,
      judges: {
        "X" => lambda { |**| x_rejudge_calls += 1; @judge.call },
        "Y" => lambda { |**| y_rejudge_calls += 1; @judge.call }
      },
      withhold_reference: false, only_missing_judges: true, plan_source: :candidate
    )

    assert_equal 0, x_rejudge_calls, "only-missing must not re-buy paid inline judge scores"
    assert_equal 1, y_rejudge_calls
    assert_empty rejudged.fetch("generation_history")
    assert_equal 8.5, rejudged.dig("cells", 0, "judges", "X", "mean")
    assert_equal 9.0, rejudged.dig("cells", 0, "judges", "Y", "mean")
    assert_equal 1, rejudged.dig("agents", "A", "judged", "scored_cells")
  end

  def test_existing_patch_does_not_promote_empty_execute_patch_on_timeout
    target = File.join(@bundle, "target")
    FileUtils.mkdir_p(File.join(target, ".hb"))
    FileUtils.rm_f(File.join(@bundle, "candidate.patch"))
    File.write(File.join(target, "candidate-execute.patch"), "")
    File.write(File.join(target, ".hb", "stages.out"),
               "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_EXIT rc=124\n")
    assert_raises(HiveBench::GenerationProvenance::Mismatch) do
      HiveBench::Rejudge.existing_patch(@bundle, @old, "base", nil)
    end
    refute_path_exists File.join(target, "candidate.patch")
  end
end
