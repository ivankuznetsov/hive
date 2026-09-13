require "set"
require "hive/canonical_json"
require "hive/plan_review/finding"

module Hive
  module PlanReview
    # Classification is a reviewer claim, not an operator decision. Reconcile
    # those claims once, retaining the originals and a disposition for each.
    module DecisionTriage
      VERSION = 1
      KEYS = %w[sources classification title disposition rationale boundary].freeze
      module_function

      def pending(record)
        assessed = Array(record["routes"]).flat_map do |route|
          route["role"] == "decision_triage" && route["triage_version"] == VERSION ?
            Array(route["assessed_fingerprints"]) : []
        end.to_set
        Array(record["findings"]).select do |entry|
          Finding.new(entry).blocking? && !assessed.include?(entry.fetch("fingerprint"))
        end
      end

      def validate!(rows, entries)
        unless rows.is_a?(Array) && !rows.empty?
          raise InvalidRecord, "decision triage must account for every pending finding"
        end
        expected = entries.map { |entry| entry.fetch("fingerprint") }.sort
        seen = []
        rows.each do |row|
          unless row.is_a?(Hash) && row.keys.sort == KEYS.sort &&
                 row["sources"].is_a?(Array) && !row["sources"].empty? &&
                 row["sources"].all? { |id| id.is_a?(String) } &&
                 %w[safe_auto gated_auto manual].include?(row["classification"]) &&
                 %w[title disposition rationale].all? { |key| row[key].is_a?(String) && !row[key].strip.empty? }
            raise InvalidRecord, "invalid decision triage disposition"
          end
          boundary = row["boundary"]
          if row["classification"] == "safe_auto"
            raise InvalidRecord, "automatic disposition cannot carry an unresolved boundary" unless boundary.nil?
          elsif !boundary.is_a?(Hash) || boundary.keys.sort != %w[alternatives change requirement] ||
                !%w[requirement change].all? { |key| boundary[key].is_a?(String) && !boundary[key].strip.empty? } ||
                !boundary["alternatives"].is_a?(Array) || boundary["alternatives"].uniq.size < 2 ||
                !boundary["alternatives"].all? { |value| value.is_a?(String) && !value.strip.empty? }
            raise InvalidRecord, "decision gate requires an unresolved contract boundary and alternatives"
          end
          seen.concat(row["sources"])
        end
        unless seen.sort == expected
          raise InvalidRecord, "decision triage sources must cover each pending finding exactly once"
        end
        rows
      end

      def apply(entries, rows, display_order: entries.map { |entry| entry.fetch("display_order") }.max.to_i)
        validate!(rows, entries)
        originals = entries.map { |entry| entry.merge("lifecycle" => "resolved") }
        replacements = rows.map.with_index do |row, index|
          sources = entries.select { |entry| row["sources"].include?(entry["fingerprint"]) }
          source = sources.first
          risk = sources.map { |entry| entry.fetch("risk") }.max_by { |value| Finding::RISKS.index(value) }
          description = [ row["disposition"], row["rationale"] ]
          if row["boundary"]
            description.concat(row["boundary"].values_at("requirement", "change"))
            description.concat(row["boundary"].fetch("alternatives"))
          end
          Finding.new(source.except("fingerprint", "decision_id", "answer", "incorporated_at", "verified_at").merge(
            "source" => "decision_triage:#{Hive::CanonicalJSON.digest(row['sources'].sort)}",
            "classification" => row["classification"], "title" => row["title"], "risk" => risk,
            "description" => description.join("\n\n"), "lifecycle" => "open",
            "display_order" => display_order + index + 1
          )).to_h
        end
        originals + replacements
      end
    end
  end
end
