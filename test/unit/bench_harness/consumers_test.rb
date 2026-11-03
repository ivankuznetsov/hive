# frozen_string_literal: true

require "support/bench_harness"
require "lib/judge_slate"
require "deliberate"
require "merge_results"
require "lib/campaign_merge"
require "hive_run"
require "pipeline_run"

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
end
