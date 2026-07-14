# frozen_string_literal: true

require "json"
require "lib/model_family"
require "lib/judge_provenance"

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
      {
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
        "efficiency" => cell[:telemetry] || {}
      }
    end

    # records: array of cell_record hashes. Returns the full results.json hash.
    def results(records:, corpus_version:, generated_at:, min_cells: PRELIMINARY_MIN_CELLS)
      by_agent = records.group_by { |r| r["agent_id"] }
      agents = by_agent.transform_values { |rs| agent_summary(rs, min_cells) }
      {
        "schema" => "hive-bench-results",
        "schema_version" => 1,
        "corpus_version" => corpus_version,
        "generated_at" => generated_at,
        "cells" => records,
        "agents" => agents
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

    def agent_summary(records, min_cells)
      gated = records.select { |r| r["subset"] == "gated" }
      judged_scored = records.select { |r| (r["judges"] || {}).any? }
      passed = gated.count { |r| r.dig("gate", "status") == "pass" }

      {
        "cells" => records.size,
        "preliminary" => records.size < min_cells,
        # How many cells actually finished cleanly vs were truncated/failed — so a
        # mean_quality built partly on timed-out partial diffs is never read as if
        # every cell completed.
        "generation" => records.each_with_object(Hash.new(0)) { |r, h| h[r["run_status"] || "unknown"] += 1 },
        "gated" => {
          "total" => gated.size,
          "passed" => passed,
          "pass_rate" => gated.empty? ? nil : (passed.to_f / gated.size).round(3)
        },
        "judged" => {
          "scored_cells" => judged_scored.size,
          # One mean per judge, so two independent judges are never collapsed.
          "mean_quality" => mean_quality_by_judge(records),
          # Same, restricted to judges family-disjoint from this candidate — the
          # only mean fit to headline (self-family scores carry preference bias).
          "mean_quality_cross_family" => mean_quality_by_judge(records, cross_family_only: true)
        },
        "efficiency" => efficiency_summary(records),
        "provenance" => {
          "reused" => records.count { |r| r["mode"] == "reused" },
          "fresh" => records.count { |r| r["mode"] == "fresh" }
        }
      }
    end

    # { "<judge>" => mean across the cells that judge scored }. With
    # cross_family_only, same-family scores are excluded (nil mean when a judge
    # only ever scored its own family). Family is RECOMPUTED from the record's
    # own fields, not read from the stored per-judge flag: merged/legacy records
    # (harness/merge_results.rb unions stored judge hashes) may predate the flag,
    # and a missing flag must never smuggle a same-family score into the headline.
    def mean_quality_by_judge(records, cross_family_only: false)
      names = records.flat_map { |r| (r["judges"] || {}).keys }.uniq
      names.to_h do |name|
        scores = records.filter_map do |r|
          j = r.dig("judges", name)
          next unless j
          next if cross_family_only && ModelFamily.same_family?(name, r["agent_id"], r["model_version"])

          j["mean"]
        end
        [name, mean_of(scores)]
      end
    end

    def efficiency_summary(records)
      costs = records.filter_map { |r| r.dig("efficiency", "cost_usd") }
      # wall-clock only from fresh cells (reused cells have none — by design).
      walls = records.select { |r| r["mode"] == "fresh" }.filter_map { |r| r.dig("efficiency", "wall_clock_sec") }
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
