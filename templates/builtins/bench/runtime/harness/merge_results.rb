# frozen_string_literal: true

# Make the harness dir importable when run directly (`ruby harness/merge_results.rb`).
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "json"
require "time"
require "score"

module HiveBench
  # Generation snapshots are explicit oldest-to-newest input. Judge-only overlays
  # are resolved afterwards and can never choose or roll back the active attempt.
  module Merge
    module_function

    def combine(results_list, corpus_version:, generated_at:, scorer: Score.new)
      history = results_list.flat_map { |r| r["generation_history"] || [] }
      cells = merge_cells(results_list.flat_map { |r| r["cells"] || [] }, history: history)
      pending = ResultEvidence.deduplicate_buckets(results_list.flat_map { |r| r["pending"] || [] })
      failed = ResultEvidence.deduplicate_buckets(results_list.flat_map { |r| r["failed"] || [] })
      out = scorer.results(records: cells, corpus_version: corpus_version, generated_at: generated_at,
                           pending: pending, failed: failed)
      out["generation_history"] = ResultEvidence.deduplicate_history(history)
      out
    end

    def merge_cells(cells, history: [])
      cells.group_by { |c| [c["agent_id"], c["task_id"]] }.filter_map do |_, group|
        snapshots, overlays = group.partition { |record| record["record_kind"] != "judge_only" }
        # A rejudge document is also usable alone. It carries the full unchanged
        # generation snapshot; ambiguous overlay-only generations stay diagnostic.
        if snapshots.empty?
          first = overlays.first
          if overlays.all? { |record| ResultEvidence.same_generation?(first, record) }
            snapshots = [first]
            overlays = overlays.drop(1)
          else
            overlays.each { |record| history << ResultEvidence.history_entry(record, "no unambiguous active generation snapshot") }
            next
          end
        end
        active = snapshots.reduce do |previous, current|
          if ResultEvidence.same_generation?(previous, current) && previous["evaluation_context"] == current["evaluation_context"]
            merge_pair(previous, current)
          else
            history << ResultEvidence.history_entry(previous, "replaced by explicitly later generation snapshot")
            if conflicting_identity?(previous, current)
              history << ResultEvidence.history_entry(current, "generation identity has inconsistent artifact bindings")
              current.merge("provenance_conflict" => true)
            else
              current
            end
          end
        end
        overlays.each do |overlay|
          if ResultEvidence.same_generation?(active, overlay) && active["evaluation_context"] == overlay["evaluation_context"]
            active = merge_pair(active, overlay)
          else
            history << ResultEvidence.history_entry(overlay, "stale or incompatible judge-only evidence")
          end
        end
        if !active["generation_id"].to_s.empty? && group.any? { |record| conflicting_identity?(active, record) }
          active = active.merge("provenance_conflict" => true)
        end
        active
      end
    end

    def conflicting_identity?(left, right)
      !left["generation_id"].to_s.empty? && left["generation_id"] == right["generation_id"] &&
        left["artifact_binding"] != right["artifact_binding"]
    end

    def merge_pair(previous, current)
      return current unless ResultEvidence.same_generation?(previous, current) &&
                            previous["evaluation_context"] == current["evaluation_context"]

      fresh = (current["judges"] || {}).select do |_, judge|
        ResultEvidence.valid_judge?(judge) && ResultEvidence.evaluation_bound?(current, judge)
      end
      # Evidence overlays have no authority over generation telemetry/subset/gate.
      result = previous.merge("judges" => (previous["judges"] || {}).merge(fresh))
      if !ResultEvidence.evaluation_bound?(previous, previous["gate"]) &&
         ResultEvidence.evaluation_bound?(current, current["gate"])
        result = result.merge("gate" => current["gate"], "subset" => current["subset"])
      end
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  require "fileutils"

  opts = { out: "runs/results.json", corpus_version: "v1" }
  OptionParser.new do |o|
    o.banner = "Usage: ruby harness/merge_results.rb [--out PATH] [--corpus-version V] <results.json>..."
    o.separator "Generation snapshots: oldest to newest; last snapshot replaces the active cell. Judge-only overlays never select generations."
    o.on("--out PATH", "combined output (default: runs/results.json)") { |v| opts[:out] = v }
    o.on("--corpus-version V", "default: v1") { |v| opts[:corpus_version] = v }
  end.parse!(ARGV)
  abort("give at least one results.json to merge") if ARGV.empty?

  results = ARGV.map { |p| JSON.parse(File.read(p)) }
  combined = HiveBench::Merge.combine(results, corpus_version: opts[:corpus_version],
                                               generated_at: Time.now.utc.iso8601)
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], "#{JSON.pretty_generate(combined)}\n")
  warn "merged #{ARGV.size} file(s) -> #{opts[:out]}: #{combined["cells"].size} cells, " \
       "agents=#{combined["agents"].keys.sort.join(", ")}"
end
