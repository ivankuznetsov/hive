require "digest"
require "time"
require "hive/daily_digest/collector"
require "hive/daily_digest/record"

module Hive
  module DailyDigest
    # Deterministic projection from one normalized collection batch into either
    # a replaceable open base, immutable closed base, or append-only amendment.
    class Projector
      def initialize(clock: -> { Time.now.utc })
        @clock = clock
      end

      def base(interval:, batch:, lifecycle:)
        now = timestamp(@clock.call)
        gaps = Array(batch.gaps)
        items = Array(batch.facts)
        attention = Array(batch.attention)
        completeness = gaps.empty? ? "complete" : "partial"
        content = content_for(items, attention, completeness)
        interval = Record.canonical_object(interval)
        {
          "schema" => Record::SCHEMA,
          "schema_version" => Record::SCHEMA_VERSION,
          **interval.slice(
            "interval_id", "local_date", "sequence", "time_zone",
            "starts_at", "ends_at", "duration_seconds", "boundary_kind", "cutover"
          ),
          "lifecycle" => lifecycle,
          "closed_at" => lifecycle == "closed" ? now : nil,
          "completeness" => completeness,
          "content" => content,
          "last_materialized_at" => now,
          "projects" => Record.canonical_object(Array(batch.projects)),
          "items" => Record.canonical_object(items),
          "attention" => Record.canonical_object(attention),
          "gaps" => Record.canonical_object(gaps),
          "source_frontiers" => Record.canonical_object(batch.frontiers.to_h)
        }
      end

      def amendment(existing:, batch:, attempted_gap_ids: nil, ended_attention_ids: [])
        existing_fact_ids = Array(existing["items"]).to_h { |item| [ item.fetch("fact_id"), true ] }
        existing_attention_ids = Array(existing["attention"]).to_h do |item|
          [ item.fetch("attention_id"), true ]
        end
        current_gaps = Array(existing["effective_gaps"] || existing["gaps"])
        batch_gaps = Array(batch.gaps)
        batch_gap_ids = batch_gaps.to_h { |gap| [ gap.fetch("gap_id"), true ] }
        new_items = Array(batch.facts).reject { |item| existing_fact_ids[item.fetch("fact_id")] }
        new_attention = Array(batch.attention).reject do |item|
          existing_attention_ids[item.fetch("attention_id")]
        end
        current_attention_ids = Array(batch.attention).to_h do |item|
          [ item.fetch("attention_id"), true ]
        end
        resolved_attention = Array(existing["attention"]).select do |item|
          !current_attention_ids[item.fetch("attention_id")] &&
            (ended_attention_ids.include?(item.fetch("attention_id")) ||
             changed_task_evidence?(existing, batch, item))
        end
        resolved_attention_ids = resolved_attention.map do |item|
          item.fetch("attention_id")
        end.sort
        known_gap_ids = current_gaps.to_h { |gap| [ gap.fetch("gap_id"), true ] }
        new_gaps = batch_gaps.reject { |gap| known_gap_ids[gap.fetch("gap_id")] }
        attempted = Array(attempted_gap_ids).to_h { |id| [ id.to_s, true ] }
        resolved_gaps = current_gaps.select do |gap|
          gap_id = gap.fetch("gap_id")
          attempted[gap_id] && !batch_gap_ids[gap_id]
        end
        resolved = resolved_gaps.map { |gap| gap.fetch("gap_id") }.sort
        return nil if new_items.empty? && new_attention.empty? && new_gaps.empty? && resolved.empty? &&
                      resolved_attention_ids.empty?

        now = timestamp(@clock.call)
        identity = {
          "local_date" => existing.fetch("local_date"),
          "prior_amendment_count" => Array(existing["amendments"]).length,
          "item_ids" => new_items.map { |item| item.fetch("fact_id") }.sort,
          "attention_ids" => new_attention.map { |item| item.fetch("attention_id") }.sort,
          "gap_ids" => new_gaps.map { |gap| gap.fetch("gap_id") }.sort,
          "resolved_gap_ids" => resolved,
          "resolved_attention_ids" => resolved_attention_ids
        }
        event_at = new_items.filter_map { |item| item["occurred_at"] }.min
        {
          "amendment_id" => "amendment:#{Record.content_id(identity)}",
          "kind" => amendment_kind(resolved, resolved_attention_ids),
          "source" => amendment_source(resolved_gaps, resolved_attention_ids),
          "event_at" => event_at,
          "observed_at" => latest_observation(new_items, new_gaps) || now,
          "amended_at" => now,
          "items" => Record.canonical_object(new_items),
          "attention" => Record.canonical_object(new_attention),
          "gaps" => Record.canonical_object(new_gaps),
          "resolved_gap_ids" => resolved,
          "resolved_gaps" => Record.canonical_object(resolved_gaps),
          "resolved_attention_ids" => resolved_attention_ids,
          "resolved_attention" => Record.canonical_object(resolved_attention),
          "source_frontiers" => Record.canonical_object(batch.frontiers.to_h)
        }
      end

      private

      def content_for(items, attention, completeness)
        return "non_empty" if items.any? || attention.any?
        return "unknown" if completeness == "partial"

        "empty"
      end

      def latest_observation(items, gaps)
        (items + gaps).filter_map { |row| row["observed_at"] }.max
      end

      def amendment_kind(resolved_gaps, resolved_attention)
        return "gap_resolution" if resolved_gaps.any?
        return "attention_resolution" if resolved_attention.any?

        "late_observation"
      end

      def amendment_source(resolved_gaps, resolved_attention)
        sources = resolved_gaps.filter_map { |gap| gap["source"] }.uniq
        return sources.first if sources.one?
        return "project_state" if resolved_attention.any?

        "daily_digest"
      end

      def changed_task_evidence?(existing, batch, attention)
        project_id = attention["project_id"]
        registration_id = attention["registration_id"]
        task_slug = attention["task_slug"].to_s
        return false if project_id.to_s.empty? || task_slug.empty?
        return false unless Collector.boundary_evidence_complete?(batch.gaps, attention)

        current = Collector.frontier_for(
          batch.frontiers, project_id: project_id, registration_id: registration_id,
          allow_legacy: registration_id.to_s.empty?
        )
        current_fingerprints = current && current["fingerprints"]
        return false unless current_fingerprints.is_a?(Hash)

        prior_frontiers = existing["effective_source_frontiers"] || existing["source_frontiers"] || {}
        prior = Collector.frontier_for(
          prior_frontiers, project_id: project_id, registration_id: registration_id,
          allow_legacy: registration_id.to_s.empty?
        )
        prior_fingerprints = prior && prior["fingerprints"]
        current_fingerprints.any? do |key, signature|
          fingerprint_task_slug(key) == task_slug &&
            (!prior_fingerprints.is_a?(Hash) || prior_fingerprints[key] != signature)
        end
      end

      def fingerprint_task_slug(key)
        parts = key.to_s.split("/", 3)
        parts.length == 3 ? parts.fetch(1) : parts.fetch(0)
      end

      def timestamp(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc.iso8601(6)
      end
    end
  end
end
