# frozen_string_literal: true

require "lib/result_evidence"

module HiveBench
  # The root carries paid backfill. Only explicitly supplied new attempts may
  # replace it; old per-cell files often survive later campaign generations.
  module CampaignMerge
    module_function

    def documents(root:, snapshots:)
      baseline = (root || { "cells" => [] }).dup
      history = Array(baseline["generation_history"]).dup
      active = baseline.fetch("cells", []).to_h { |cell| [[cell["agent_id"], cell["task_id"]], cell] }
      generations = []
      overlays = []
      snapshots.each do |document|
        selected = []
        document.fetch("cells", []).each do |cell|
          key = [cell["agent_id"], cell["task_id"]]
          current = active[key]
          id = cell["generation_id"]
          if current && !id.to_s.empty? && id == current["generation_id"]
            overlays << { "cells" => [cell.merge("record_kind" => "judge_only")] }
          elsif !id.to_s.empty? && history.any? { |entry| entry.values_at("agent_id", "task_id", "generation_id") == [*key, id] }
            next
          elsif current.nil? || (!id.to_s.empty? && cell["record_kind"] == "generation")
            selected << cell
            active[key] = cell
          elsif cell != current
            history << ResultEvidence.history_entry(cell, "ambiguous per-cell legacy evidence; select artifacts for rejudging")
          end
        end
        # Stale per-cell buckets must not re-arm generation or charge old work.
        # Existing root buckets and parked-only snapshots (limit_hit/crash with
        # no cell entry) are retained as operational evidence unless retired.
        document_cell_keys = document.fetch("cells", []).map { |cell| [cell["agent_id"], cell["task_id"]] }
        keys = selected.map { |cell| cell.values_at("agent_id", "task_id", "generation_id") }
        filtered = document.merge("cells" => selected)
        %w[pending failed].each do |bucket|
          filtered[bucket] = document.fetch(bucket, []).select do |record|
            key = [record["agent_id"], record["task_id"]]
            id = record["generation_id"]
            if document_cell_keys.include?(key)
              keys.include?([*key, id])
            else
              id.to_s.empty? || !history.any? { |entry| entry.values_at("agent_id", "task_id", "generation_id") == [*key, id] }
            end
          end
        end
        generations << filtered unless selected.empty? && filtered["pending"].empty? && filtered["failed"].empty?
      end
      baseline["generation_history"] = ResultEvidence.deduplicate_history(history)
      [baseline, *generations, *overlays]
    end
  end
end
