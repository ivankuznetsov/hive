# frozen_string_literal: true

require "json"
require "lib/model_family"
require "lib/judge_provenance"
require "lib/result_evidence"

module HiveBench
  # Scoring tier 3 + assembly. Combines a cell's gate verdict, judge result, and
  # efficiency telemetry into one cell record, then aggregates cells per agent
  # into the results.json the leaderboard (U7) renders.
  #
  # The aggregate keeps the gated and judged subsets SEPARATE (the gate is the
  # objective floor; judged-only cells have no gate), and flags an agent
  # "preliminary" below a minimum cell count so a thin sample isn't ranked as if
  # it were settled (the LMSYS pattern).
  class Score
    PRELIMINARY_MIN_CELLS = 10

    # cell: { task_id, agent_id, mode, model_version, run_status, telemetry }
    # gate: HiveBench::Gate::Result
    # judges: { "<judge-name>" => HiveBench::Judge::Result } (empty when no diff)
    def cell_record(cell:, gate:, judges:)
      record = {
        "task_id" => cell.fetch(:task_id),
        "agent_id" => cell.fetch(:agent_id),
        "mode" => cell.fetch(:mode),
        "model_version" => cell[:model_version],
        # The generation outcome (generated / empty_diff / timed_out / agent_failed)
        # so a truncated or failed run is never mistaken for a clean completion.
        "run_status" => cell[:run_status],
        "subset" => gate.subset,
        "gate" => { "status" => gate.status.to_s, "reason" => gate.reason },
        # One entry per independent judge (e.g. opus-4.8 + gpt-5.5-pro). A judge
        # sharing a model family with the candidate is flagged `same_family` —
        # self-preference bias means those scores can't headline a leaderboard.
        "judges" => judge_records(judges, cell),
        "efficiency" => cell[:telemetry] || {},
        "record_kind" => cell[:record_kind] || "generation",
        "generation_id" => cell[:generation_id],
        "artifact_binding" => cell[:artifact_binding],
        "evaluation_context" => cell[:evaluation_context]
      }
      if ResultEvidence.bound_generation?(record) && ResultEvidence.valid_context?(record["evaluation_context"])
        record["gate"]["evidence_binding"] = ResultEvidence.binding(record)
        record["judges"].each_value { |judge| judge["evidence_binding"] = ResultEvidence.binding(record) }
      end
      record
    end

    # records: array of cell_record hashes. Returns the full results.json hash.
    def results(records:, corpus_version:, generated_at:, min_cells: PRELIMINARY_MIN_CELLS, pending: [], failed: [])
      pending = ResultEvidence.deduplicate_buckets(pending)
      failed = ResultEvidence.deduplicate_buckets(failed)
      # Adoption explicitly identifies the original legacy snapshot. This avoids
      # charging its overlapping parked entry again without inferring continuity
      # from a cell key or equal patch bytes.
      adopted = records.filter_map { |record| record["adopted_attempt_snapshot_sha256"] }
      parked = (pending + failed).reject { |record| adopted.include?(ResultEvidence.snapshot_digest(record)) }
      attempts = ResultEvidence.deduplicate_buckets(parked + records)
      agents = attempts.group_by { |r| r["agent_id"] }.to_h do |agent, tried|
        active = records.select { |r| r["agent_id"] == agent }
        [agent, agent_summary(active, tried, min_cells)]
      end
      {
        "schema" => "hive-bench-results", "schema_version" => 2,
        "corpus_version" => corpus_version, "generated_at" => generated_at,
        "cells" => records, "agents" => agents, "pending" => pending, "failed" => failed,
        "rejudging_needed" => records.filter_map do |record|
          reasons = ResultEvidence.rejudging_reasons(record)
          next if reasons.empty?

          record.slice("agent_id", "task_id", "generation_id").merge("reasons" => reasons)
        end
      }
    end

    private

    def judge_records(judges, cell)
      (judges || {}).to_h do |name, j|
        record = { "mean" => j.mean, "stddev" => j.stddev,
                   "scores" => j.scores, "sample_count" => j.scores.size,
                   "reasons" => j.reasons, "interval" => j.interval,
                   "reference_withheld" => j.reference_withheld,
                   "same_family" => ModelFamily.same_family?(name, cell[:agent_id], cell[:model_version]) }
        [name, record.merge(JudgeProvenance.metadata(name))]
      end
    end

    def agent_summary(records, attempts, min_cells)
      eligible = attempts.select { |r| ResultEvidence.execution_eligible?(r) }
      ranked = records.map { |r| r.merge("judges" => ResultEvidence.admitted_judges(r)) }
      gates = records.select { |r| ResultEvidence.admitted_gate?(r) }
      diagnostics = records.map do |r|
        admitted = ResultEvidence.admitted_judges(r)
        r.merge("judges" => (r["judges"] || {}).reject { |name, _| admitted.key?(name) })
      end
      diagnostic_gates = records.select { |r| r["subset"] == "gated" && !ResultEvidence.admitted_gate?(r) }
      attempted_cells = attempts.map { |r| [r["agent_id"], r["task_id"]] }.uniq.size
      {
        "cells" => records.size,
        "preliminary" => eligible.empty? || eligible.size < min_cells || eligible.size < attempted_cells,
        "generation" => attempts.each_with_object(Hash.new(0)) { |r, h| h[r["run_status"] || "unknown"] += 1 },
        "coverage" => { "attempted_cells" => attempted_cells, "attempts" => attempts.size,
                        "eligible_executions" => eligible.size,
                        "eligible_fraction" => attempted_cells.zero? ? nil : (eligible.size.to_f / attempted_cells).round(3),
                        "judged_cells" => ranked.count { |r| r["judges"].any? }, "gated_cells" => gates.size },
        "gated" => gate_summary(gates), "judged" => judged_summary(ranked),
        "efficiency" => efficiency_summary(attempts).merge(
          "eligible" => efficiency_summary(eligible),
          "diagnostic" => efficiency_summary(attempts.reject { |r| ResultEvidence.execution_eligible?(r) })
        ),
        "diagnostics" => { "judged" => judged_summary(diagnostics), "gated" => gate_summary(diagnostic_gates),
                           "efficiency" => efficiency_summary(attempts.reject { |r| ResultEvidence.execution_eligible?(r) }) },
        "provenance" => %w[fresh reused pipeline hive].to_h { |mode| [mode, attempts.count { |r| r["mode"] == mode }] }
      }
    end

    def gate_summary(records)
      valid = records.select { |r| %w[pass fail].include?(r.dig("gate", "status")) }
      passed = valid.count { |r| r.dig("gate", "status") == "pass" }
      { "total" => valid.size, "passed" => passed, "pass_rate" => valid.empty? ? nil : (passed.to_f / valid.size).round(3) }
    end

    def judged_summary(records)
      { "scored_cells" => records.count { |r| (r["judges"] || {}).values.any? { |j| ResultEvidence.valid_judge?(j) } },
        "mean_quality" => mean_quality_by_judge(records),
        "mean_quality_cross_family" => mean_quality_by_judge(records, cross_family_only: true),
        "samples_by_judge" => records.flat_map { |r| (r["judges"] || {}).keys }.uniq.to_h do |name|
          [name, records.count { |r| ResultEvidence.valid_judge?(r.dig("judges", name)) }]
        end }
    end

    def mean_quality_by_judge(records, cross_family_only: false)
      names = records.flat_map { |r| (r["judges"] || {}).keys }.uniq
      names.to_h do |name|
        scores = records.filter_map do |r|
          judge = r.dig("judges", name)
          next unless ResultEvidence.valid_judge?(judge)
          next if cross_family_only && ModelFamily.same_family?(name, r["agent_id"], r["model_version"])

          judge["mean"]
        end
        [name, mean_of(scores)]
      end
    end

    def efficiency_summary(records)
      costs = records.filter_map { |r| r.dig("efficiency", "cost_usd") }
      # Measured execution time for every executing producer; reuse has no new execution.
      walls = records.select { |r| %w[fresh pipeline hive].include?(r["mode"]) }.filter_map { |r| r.dig("efficiency", "wall_clock_sec") }
      {
        "total_cost_usd" => costs.empty? ? nil : costs.sum.round(4),
        "mean_wall_clock_sec" => mean_of(walls),
        "wall_clock_sample" => walls.size
      }
    end

    def mean_of(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round(3)
    end
  end
end
