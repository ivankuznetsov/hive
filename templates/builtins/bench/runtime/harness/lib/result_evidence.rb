# frozen_string_literal: true

require "json"
require "digest"

module HiveBench
  # Admission is derived from source fields on every read, including legacy and
  # mixed-vintage documents. Stored summaries/eligibility flags have no authority.
  module ResultEvidence
    SUCCESS_STATUSES = %w[generated empty_diff].freeze
    RECORD_KINDS = %w[generation judge_only].freeze
    module_function

    def execution_eligible?(record)
      SUCCESS_STATUSES.include?(record["run_status"])
    end

    def digest?(value) = value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    def bound_generation?(record)
      binding = record["artifact_binding"]
      !record["generation_id"].to_s.empty? && RECORD_KINDS.include?(record["record_kind"]) &&
        binding.is_a?(Hash) && binding["task_id"] == record["task_id"] &&
        !binding["base_commit"].to_s.empty? && digest?(binding["patch_sha256"]) && digest?(binding["plan_sha256"])
    end

    def valid_context?(context)
      context.is_a?(Hash) && digest?(context["plan_sha256"]) &&
        (%w[withheld unavailable].include?(context["reference_mode"]) ||
          (context["reference_mode"] == "provided" && digest?(context["reference_sha256"])))
    end

    def binding(record)
      record.slice("generation_id", "artifact_binding", "evaluation_context")
    end

    def same_generation?(left, right)
      bound_generation?(left) && bound_generation?(right) &&
        left["generation_id"] == right["generation_id"] && left["artifact_binding"] == right["artifact_binding"]
    end

    def evaluation_bound?(record, evaluation)
      bound_generation?(record) && valid_context?(record["evaluation_context"]) &&
        evaluation.is_a?(Hash) && evaluation["evidence_binding"] == binding(record)
    end

    def valid_judge?(judge)
      judge.is_a?(Hash) && judge["mean"].is_a?(Numeric) && judge["mean"].finite? && judge["mean"].between?(0, 10)
    end

    def admitted_judges(record)
      return {} unless execution_eligible?(record)

      (record["judges"] || {}).select { |_, judge| valid_judge?(judge) && evaluation_bound?(record, judge) }
    end

    def admitted_gate?(record)
      execution_eligible?(record) && record["subset"] == "gated" &&
        %w[pass fail].include?(record.dig("gate", "status")) && evaluation_bound?(record, record["gate"])
    end

    def rejudging_reasons(record)
      reasons = []
      reasons << "execution status is not eligible: #{record['run_status'] || 'unknown'}" unless execution_eligible?(record)
      reasons << "select current artifacts and establish generation identity before rejudging" unless bound_generation?(record)
      reasons << "evaluation context is missing or invalid" unless valid_context?(record["evaluation_context"])
      if (record["judges"] || {}).any? { |_, j| !evaluation_bound?(record, j) }
        reasons << "fresh judging required: unbound or conflicting judge evidence"
      end
      if record["subset"] == "gated" && !evaluation_bound?(record, record["gate"])
        reasons << "fresh gating required"
      end
      reasons.concat(Array(record["rejudging_reasons"]))
      reasons.uniq
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def snapshot_digest(record) = Digest::SHA256.hexdigest(JSON.generate(canonical(record)))

    def deduplicate_buckets(records)
      records.group_by { |r| [r["agent_id"], r["task_id"], r["generation_id"]] }.values.map do |group|
        group.reduce do |prev, cur|
          prev.merge(cur).merge("efficiency" => (prev["efficiency"] || {}).merge(cur["efficiency"] || {}))
        end
      end
    end
  end
end
