require "digest"
require "time"
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

      def amendment(existing:, batch:)
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
        known_gap_ids = current_gaps.to_h { |gap| [ gap.fetch("gap_id"), true ] }
        new_gaps = batch_gaps.reject { |gap| known_gap_ids[gap.fetch("gap_id")] }
        resolved = current_gaps.filter_map do |gap|
          gap.fetch("gap_id") unless batch_gap_ids[gap.fetch("gap_id")]
        end.sort
        return nil if new_items.empty? && new_attention.empty? && new_gaps.empty? && resolved.empty?

        now = timestamp(@clock.call)
        identity = {
          "local_date" => existing.fetch("local_date"),
          "item_ids" => new_items.map { |item| item.fetch("fact_id") }.sort,
          "attention_ids" => new_attention.map { |item| item.fetch("attention_id") }.sort,
          "gap_ids" => new_gaps.map { |gap| gap.fetch("gap_id") }.sort,
          "resolved_gap_ids" => resolved
        }
        event_at = new_items.filter_map { |item| item["occurred_at"] }.min
        {
          "amendment_id" => "amendment:#{Record.content_id(identity)}",
          "kind" => resolved.any? ? "gap_resolution" : "late_observation",
          "source" => "daily_digest",
          "event_at" => event_at,
          "observed_at" => latest_observation(new_items, new_gaps) || now,
          "amended_at" => now,
          "items" => Record.canonical_object(new_items),
          "attention" => Record.canonical_object(new_attention),
          "gaps" => Record.canonical_object(new_gaps),
          "resolved_gap_ids" => resolved,
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

      def timestamp(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc.iso8601(6)
      end
    end
  end
end
