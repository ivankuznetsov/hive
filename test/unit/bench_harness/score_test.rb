# frozen_string_literal: true

require "support/bench_harness"
require "score"

class BenchHarnessScoreTest < Minitest::Test
  def record(status = "generated", task: "t", mode: "hive")
    binding = { "task_id" => task, "base_commit" => "base", "patch_sha256" => "a" * 64,
                "plan_sha256" => "b" * 64 }
    context = { "plan_sha256" => "b" * 64, "reference_mode" => "withheld" }
    evidence = { "generation_id" => task, "artifact_binding" => binding, "evaluation_context" => context }
    { "task_id" => task, "agent_id" => "A", "run_status" => status, "mode" => mode,
      "record_kind" => "generation", "generation_id" => task, "artifact_binding" => binding,
      "evaluation_context" => context, "subset" => "gated",
      "gate" => { "status" => "pass", "evidence_binding" => evidence },
      "judges" => { "X" => { "mean" => 9.0, "scores" => [9.0], "evidence_binding" => evidence } },
      "efficiency" => { "cost_usd" => 2.0, "wall_clock_sec" => 4.0 } }
  end

  def results(records, **kwargs)
    HiveBench::Score.new.results(records: JSON.parse(JSON.generate(records)), corpus_version: "v", generated_at: "now", **kwargs)
  end

  def test_only_successful_bound_evidence_ranks_and_failures_keep_costs
    statuses = ["generated", "timed_out", "agent_failed", "plan_failed", "execute_failed", nil, "future_status"]
    out = results(statuses.map.with_index { |status, i| record(status, task: i.to_s) })
    agent = out.fetch("agents").fetch("A")
    assert_equal 2, out.fetch("schema_version")
    assert_equal 7, agent.fetch("cells")
    assert_equal 1, agent.dig("coverage", "eligible_executions")
    assert_equal 1, agent.dig("judged", "scored_cells")
    assert_equal 1, agent.dig("gated", "total")
    assert_equal 9.0, agent.dig("judged", "mean_quality", "X")
    assert_equal 14.0, agent.dig("efficiency", "total_cost_usd")
    assert_equal 6, agent.dig("diagnostics", "judged", "scored_cells")
    assert_equal 1, agent.dig("generation", "unknown")
  end

  def test_all_ineligible_is_preliminary_and_unranked_even_above_minimum
    agent = results(12.times.map { |i| record("timed_out", task: i.to_s) }, min_cells: 10).dig("agents", "A")
    assert agent.fetch("preliminary")
    assert_equal 0, agent.dig("judged", "scored_cells")
    assert_nil agent.dig("judged", "mean_quality", "X")
    assert_nil agent.dig("gated", "pass_rate")
    assert_equal 24.0, agent.dig("diagnostics", "efficiency", "total_cost_usd")
  end

  def test_legacy_and_forged_evaluations_are_diagnostic_in_mixed_documents
    legacy = record(task: "legacy").reject { |key, _| %w[generation_id artifact_binding record_kind evaluation_context].include?(key) }
    forged = record(task: "forged")
    forged["gate"]["evidence_binding"]["generation_id"] = "other"
    out = results([record, legacy, forged])
    assert_equal 1, out.dig("agents", "A", "judged", "scored_cells")
    assert_equal 1, out.dig("agents", "A", "gated", "total")
    assert out.fetch("rejudging_needed").any? { |item| item["task_id"] == "legacy" }
  end

  def test_empty_diff_is_eligible_without_invented_quality
    empty = record("empty_diff")
    empty["judges"] = {}
    agent = results([empty]).dig("agents", "A")
    assert_equal 1, agent.dig("coverage", "eligible_executions")
    assert_equal 0, agent.dig("judged", "scored_cells")
    assert_equal 1, agent.dig("gated", "total")
    assert_nil agent.dig("judged", "mean_quality", "X")
  end

  def test_wall_clock_includes_fresh_pipeline_and_hive_but_not_reused
    agent = results(%w[fresh reused pipeline hive].map { |mode| record(task: mode, mode: mode) }).dig("agents", "A")
    assert_equal 3, agent.dig("efficiency", "wall_clock_sample")
    assert_equal 4.0, agent.dig("efficiency", "mean_wall_clock_sec")
    %w[fresh reused pipeline hive].each { |mode| assert_equal 1, agent.dig("provenance", mode) }
  end

  def test_parked_attempts_count_and_overlap_is_not_charged_twice
    active = record
    parked = record("limit_hit", task: "limit")
    out = results([active], pending: [active, parked], failed: [active])
    agent = out.dig("agents", "A")
    assert_equal 2, agent.dig("coverage", "attempted_cells")
    assert_equal 4.0, agent.dig("efficiency", "total_cost_usd")
    assert_equal 1, agent.dig("generation", "limit_hit")
    only_parked = results([], pending: [parked]).dig("agents", "A")
    assert only_parked.fetch("preliminary")
    assert_equal 2.0, only_parked.dig("efficiency", "total_cost_usd")
  end
end
