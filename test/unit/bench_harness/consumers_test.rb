# frozen_string_literal: true

require "support/bench_harness"
require "lib/judge_slate"
require "deliberate"
require "merge_results"
require "lib/campaign_merge"
require "hive_run"
require "pipeline_run"
require "open3"
require "rbconfig"

class BenchHarnessConsumersTest < Minitest::Test
  def cell(id = "a", status: "generated")
    value = { "task_id" => "t", "agent_id" => "A", "generation_id" => id, "record_kind" => "generation",
              "run_status" => status, "mode" => "hive", "subset" => "judged", "gate" => {},
              "artifact_binding" => { "task_id" => "t", "base_commit" => "base", "patch_sha256" => "a" * 64, "plan_sha256" => "b" * 64 },
              "evaluation_context" => { "plan_sha256" => "b" * 64, "reference_mode" => "withheld" },
              "efficiency" => { "cost_usd" => 2.0 } }
    value["judges"] = { "X" => { "mean" => 8.0, "sample_count" => 1, "evidence_binding" => HiveBench::ResultEvidence.binding(value) } }
    value
  end

  def campaign
    { "tasks" => [ "t" ], "candidates" => [ "A" ], "seeds" => 1,
      "judges" => { "claude" => { "model" => "claude-X" } } }
  end

  def test_permissive_limit_record_uses_manual_missing_cell_route
    validation = HiveBench::JudgeSlate.validate(data: { "cells" => [ cell(status: "limit_hit") ] }, campaign: campaign)
    assert validation.manual.any? { |reason| reason.start_with?("MISSING_CELL") }
    assert_empty validation.retryable
    assert_empty validation.incomplete_keys
  end

  def test_unbound_judges_never_satisfy_current_slate
    record = cell
    assert_empty HiveBench::JudgeSlate.validate(data: { "cells" => [ record ] }, campaign: campaign).problems
    record["judges"]["X"]["evidence_binding"] = { "generation_id" => "old" }
    assert HiveBench::JudgeSlate.validate(data: { "cells" => [ record ] }, campaign: campaign).retryable.any?
  end

  def test_deliberation_identity_rotates_even_when_artifacts_are_identical
    a, b = cell("a"), cell("b")
    refute_equal HiveBench::ResultEvidence.evaluation_key(a), HiveBench::ResultEvidence.evaluation_key(b)
    legacy = a.reject { |key, _| key == "generation_id" }
    assert_nil HiveBench::ResultEvidence.evaluation_key(legacy)
    verdict = HiveBench::Deliberation::Verdict.new(initial: 8.0, initial_reason: "first", final: 7.0,
                                                  final_reason: "last", discussion: "checked")
    transcript = HiveBench::DeliberateCli.transcript(a, { "X" => verdict })
    assert_equal HiveBench::ResultEvidence.evaluation_key(a), HiveBench::ResultEvidence.evaluation_key(transcript)
  end
  def test_campaign_handoff_retains_backfill_and_skips_retired_snapshots
    a, b = cell("a"), cell("b")
    b["judges"]["Y"] = b["judges"]["X"].merge("mean" => 9.0)
    root = HiveBench::Merge.combine([ { "cells" => [ a ] }, { "cells" => [ b ] } ], corpus_version: "v", generated_at: "now")
    root["cells"].first["record_kind"] = "judge_only"
    docs = HiveBench::CampaignMerge.documents(root: root, snapshots: [ { "cells" => [ a ] } ])
    merged = HiveBench::Merge.combine(docs, corpus_version: "v", generated_at: "now")
    assert_equal "b", merged["cells"].first["generation_id"]
    assert_equal %w[X Y], merged["cells"].first["judges"].keys
    c = cell("c")
    docs = HiveBench::CampaignMerge.documents(root: root, snapshots: [ { "cells" => [ a ] }, { "cells" => [ c ] } ])
    merged = HiveBench::Merge.combine(docs, corpus_version: "v", generated_at: "now")
    assert_equal "c", merged["cells"].first["generation_id"]
    assert_equal [ "X" ], merged["cells"].first["judges"].keys
  end

  def test_all_standalone_summaries_label_ranked_and_diagnostic_evidence
    cells = [ cell, cell("failed", status: "timed_out").merge("task_id" => "failed") ]
    results = HiveBench::Score.new.results(records: cells, corpus_version: "v", generated_at: "now")
    outcome = HiveBench::RunAll::Outcome.new(results: results, pending: [], failed: [])
    Dir.mktmpdir("bench-standalone") do |dir|
      [ HiveBench::Driver, HiveBench::HiveRun, HiveBench::PipelineDriver ].each do |driver|
        _out, err = capture_io { driver.write_and_report(outcome, { out: dir }) }
        assert_includes err, "attempted=2 eligible=1 judged=1 gated=0 preliminary=true"
        assert_includes err, "X=8.0"
        assert_includes err, "diagnostic_judges=1"
      end
    end
  end

  def test_deliberation_skips_ineligible_failed_cells
    Dir.mktmpdir("bench-delib-ineligible") do |root|
      corpus = File.join(root, "corpus")
      runs = File.join(root, "runs")
      %w[ok timed].each do |task|
        entry_dir = File.join(corpus, task)
        FileUtils.mkdir_p(entry_dir)
        File.write(File.join(entry_dir, "plan.md"), "plan\n")
        File.write(File.join(entry_dir, "manifest.yml"), YAML.dump(
          "task_id" => task, "source" => { "base_commit" => "base" }, "spec" => { "plan" => "plan.md" }
        ))
        bundle = File.join(runs, task, "A")
        FileUtils.mkdir_p(bundle)
        File.write(File.join(bundle, "candidate.patch"), "+change\n")
        manifest = HiveBench::GenerationProvenance.start!(
          out_dir: bundle, entry: { "task_id" => task, "source" => { "base_commit" => "base" } },
          agent_id: "A", clear_artifacts: false
        )
        HiveBench::GenerationProvenance.finalize!(
          out_dir: bundle, manifest: manifest, diff_path: File.join(bundle, "candidate.patch"),
          plan: "plan\n", status: task == "ok" ? "generated" : "timed_out"
        )
      end

      make_cell = lambda do |task, status|
        manifest = HiveBench::GenerationProvenance.load(File.join(runs, task, "A"))
        ctx = HiveBench::GenerationProvenance.context(plan: "plan\n", reference: nil, withheld: true)
        rec = { "task_id" => task, "agent_id" => "A", "generation_id" => manifest["generation_id"],
                "record_kind" => "generation", "run_status" => status, "mode" => "hive",
                "subset" => "judged", "gate" => {}, "artifact_binding" => manifest["artifact_binding"],
                "evaluation_context" => ctx, "efficiency" => {} }
        ev = HiveBench::ResultEvidence.binding(rec)
        rec["judges"] = {
          "X" => { "mean" => 4.0, "sample_count" => 1, "evidence_binding" => ev },
          "Y" => { "mean" => 9.0, "sample_count" => 1, "evidence_binding" => ev }
        }
        rec
      end

      ok_cell = make_cell.call("ok", "generated")
      failed_cell = make_cell.call("timed", "timed_out")

      called_tasks = []
      fake_judge = ->(prompt:, seed:) { called_tasks << prompt; { score: 7.0, reason: "ok", discussion: "ok" } }
      out = nil
      capture_io do
        out = HiveBench::DeliberateCli.run(
          cells: [ ok_cell, failed_cell ], search_dirs: [ runs ], source: "unused", corpus_root: corpus,
          judge_fns: { "X" => fake_judge, "Y" => fake_judge }, withhold_reference: true
        )
      end
      assert_equal [ "ok" ], out.fetch("cells").map { |c| c["task_id"] }

      # Also exercise deliberate.rb CLI selection against the timed-out cell alone.
      results_path = File.join(root, "results.json")
      delib_path = File.join(root, "deliberation.json")
      File.write(results_path, JSON.generate("cells" => [ failed_cell ]))
      deliberate_rb = File.join(BenchHarness::HARNESS_ROOT, "deliberate.rb")
      _stdout, err, status = Open3.capture3(
        RbConfig.ruby, deliberate_rb, "--source", root, "--corpus", corpus,
        "--results", results_path, "--out", delib_path, "--withhold-reference",
        "--min-disagreement", "0", "--claude-judge", "--codex-judge", "--no-openrouter-judge", runs
      )
      assert status.success?, err
      assert_includes err, "deliberating 0 cell(s)"
      assert_empty JSON.parse(File.read(delib_path)).fetch("cells")
    end
  end

  def test_campaign_merge_preserves_parked_only_limit_hit_and_crash_snapshots
    a, b = cell("a"), cell("b")
    root = HiveBench::Merge.combine([ { "cells" => [ a ] }, { "cells" => [ b ] } ], corpus_version: "v", generated_at: "now")
    limit_hit = { "task_id" => "t-limit", "agent_id" => "A", "generation_id" => "g-limit",
                  "run_status" => "limit_hit", "mode" => "hive", "reason" => "quota",
                  "efficiency" => { "cost_usd" => 1.5 } }
    crash = { "task_id" => "t-crash", "agent_id" => "A", "generation_id" => nil,
              "run_status" => nil, "mode" => nil, "reason" => "RuntimeError: boom",
              "efficiency" => {} }
    retired_parked = { "task_id" => "t", "agent_id" => "A", "generation_id" => "a",
                       "run_status" => "limit_hit", "mode" => "hive", "reason" => "old quota",
                       "efficiency" => { "cost_usd" => 9.0 } }
    snapshots = [
      { "cells" => [], "pending" => [ limit_hit ], "failed" => [] },
      { "cells" => [], "pending" => [], "failed" => [ crash ] },
      { "cells" => [ a ], "pending" => [ retired_parked ], "failed" => [] },
      { "cells" => [], "pending" => [ retired_parked ], "failed" => [] }
    ]
    docs = HiveBench::CampaignMerge.documents(root: root, snapshots: snapshots)
    merged = HiveBench::Merge.combine(docs, corpus_version: "v", generated_at: "now")
    assert_equal [ "t-limit" ], merged.fetch("pending").map { |r| r["task_id"] }
    assert_equal [ "t-crash" ], merged.fetch("failed").map { |r| r["task_id"] }
    assert_equal 3, merged.dig("agents", "A", "coverage", "attempted_cells")
    assert_equal 3.5, merged.dig("agents", "A", "efficiency", "total_cost_usd")
    assert_equal 1, merged.dig("agents", "A", "operational_failures", "pending_attempts")
    assert_equal 1, merged.dig("agents", "A", "operational_failures", "failed_attempts")
  end
end
