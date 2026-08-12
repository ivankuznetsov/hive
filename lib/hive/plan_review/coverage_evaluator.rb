require "hive/plan_review"
require "hive/plan_review/record"

module Hive
  module PlanReview
    module CoverageEvaluator
      CORE = %w[whole_document adversarial].freeze

      Result = Data.define(:status, :degradation_reason, :blockers, :counts) do
        def complete? = status == "complete"
        def degraded? = status == "degraded"
        def blocked? = status == "blocked"
      end

      module_function

      def evaluate(level:, coverage:, adapter_outcomes: [], verification_outcome: nil)
        level = Hive::PlanReview.level!(level)
        rows = normalize(coverage)
        required = rows.select { |row| row.fetch("required") }
        required += rows.reject { |row| row.fetch("required") } if level == "mandatory"
        required = required.uniq { |row| row.fetch("name") }
        missing = required.reject { |row| %w[completed waived].include?(row.fetch("status")) }
        core_complete = CORE.all? do |name|
          rows.any? { |row| row.fetch("name") == name && %w[completed waived].include?(row.fetch("status")) }
        end
        optional_failed = rows.any? do |row|
          !row.fetch("required") && %w[failed unsupported].include?(row.fetch("status"))
        end
        verification_failed = verification_outcome &&
                              !%w[success partial_coverage].include?(verification_outcome.to_s)

        if missing.empty? && !verification_failed
          return result(optional_failed ? "degraded" : "complete",
                        optional_failed ? "partial_coverage" : nil, [], rows)
        end

        blockers = missing.map do |row|
          {
            "owner" => "operator",
            "reason" => "coverage_#{row.fetch('status')}",
            "coverage" => row.fetch("name")
          }
        end
        if verification_failed
          blockers << { "owner" => "reviewer", "reason" => "verification_#{verification_outcome}" }
        end
        return result("blocked", nil, blockers, rows) if level == "mandatory"

        reason = if core_complete
          "partial_coverage"
        elsif Array(adapter_outcomes).all? { |outcome| outcome.to_s == "unsupported" }
          "review_unavailable"
        else
          "terminal_failure"
        end
        result("degraded", reason, [], rows)
      end

      def merge(requested:, observed:, outcome:)
        by_name = Array(observed).to_h { |row| [ string_hash(row)["name"], string_hash(row) ] }
        Array(requested).map do |request|
          request = string_hash(request)
          row = by_name[request.fetch("name")] || {}
          status = row["status"]
          status = inferred_status(outcome) unless Record::COVERAGE_STATUSES.include?(status)
          {
            "name" => request.fetch("name"),
            "required" => request.fetch("required"),
            "status" => status,
            "reason" => row["reason"],
            "retry_at" => row["retry_at"]
          }.compact.freeze
        end.freeze
      end

      def combine(*groups)
        groups.flatten.compact.each_with_object({}) do |entry, result|
          row = string_hash(entry)
          name = row.fetch("name")
          previous = result[name]
          result[name] = preferred(previous, row)
        end.values.sort_by { |row| row.fetch("name") }.freeze
      end

      def normalize(coverage)
        Array(coverage).map do |entry|
          row = string_hash(entry)
          unless row["name"].to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/) &&
                 (row["required"] == true || row["required"] == false) &&
                 Record::COVERAGE_STATUSES.include?(row["status"])
            raise InvalidRecord, "invalid plan review coverage entry"
          end
          row.freeze
        end
      end

      def inferred_status(outcome)
        case outcome.to_s
        when "success", "partial_coverage" then "failed"
        when "unsupported" then "unsupported"
        else "failed"
        end
      end
      private_class_method :inferred_status

      def preferred(left, right)
        return right unless left

        rank = { "requested" => 0, "failed" => 1, "unsupported" => 1, "completed" => 2, "waived" => 3 }
        rank.fetch(right.fetch("status")) >= rank.fetch(left.fetch("status")) ? right : left
      end
      private_class_method :preferred

      def result(status, reason, blockers, rows)
        counts = Record::COVERAGE_STATUSES.to_h do |value|
          [ value, rows.count { |row| row.fetch("status") == value } ]
        end.freeze
        Result.new(status:, degradation_reason: reason, blockers: blockers.freeze, counts:).freeze
      end
      private_class_method :result

      def string_hash(value)
        value.to_h { |key, child| [ key.to_s, child ] }
      end
      private_class_method :string_hash
    end
  end
end
