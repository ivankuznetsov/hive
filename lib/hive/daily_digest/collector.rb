require "time"
require "hive/daily_digest/materiality"
require "hive/daily_digest/project_source"

module Hive
  module DailyDigest
    # Isolates every registered project source and returns one normalized batch.
    # The batch is side-effect free; U3 owns committing its facts and frontiers.
    class Collector
      Result = Data.define(
        :projects, :facts, :attention, :gaps, :frontiers, :completeness, :content
      )

      class << self
        def frontier_key(project)
          row = stringify_hash(project)
          project_id = row.fetch("project_id").to_s
          registration_id = row["registration_id"].to_s
          registration_id.empty? ? project_id : "#{project_id}:#{registration_id}"
        end

        def normalize_frontier(frontier, project:)
          row = stringify_hash(frontier)
          identity = stringify_hash(project)
          row["project_id"] = identity.fetch("project_id")
          registration_id = identity["registration_id"]
          row["registration_id"] = registration_id unless registration_id.to_s.empty?
          row
        end

        def frontier_for(frontiers, project_id:, registration_id: nil, allow_legacy: true)
          rows = stringify_hash(frontiers)
          identity = { "project_id" => project_id, "registration_id" => registration_id }
          exact_key = frontier_key(identity)
          return rows[exact_key] if rows.key?(exact_key)

          candidates = rows.filter_map do |key, frontier|
            next unless frontier.is_a?(Hash)

            frontier_project = frontier["project_id"] || (key unless key.include?(":"))
            next unless frontier_project.to_s == project_id.to_s
            next if !registration_id.to_s.empty? &&
                    frontier["registration_id"].to_s != registration_id.to_s

            frontier
          end
          return candidates.first if candidates.one?
          return unless allow_legacy

          legacy = rows[project_id.to_s]
          return unless legacy.is_a?(Hash)
          return if !registration_id.to_s.empty? && !legacy["registration_id"].to_s.empty? &&
                    legacy["registration_id"].to_s != registration_id.to_s

          legacy
        end

        def boundary_evidence_complete?(gaps, attention)
          item = stringify_hash(attention)
          Array(gaps).none? do |value|
            gap = stringify_hash(value)
            next false unless %w[project_registry project_state task_journal].include?(gap["source"])
            next true if gap["source"] == "project_registry"
            next false unless gap["project_id"].to_s == item["project_id"].to_s
            next false unless gap["registration_id"].to_s.empty? ||
                              item["registration_id"].to_s.empty? ||
                              gap["registration_id"].to_s == item["registration_id"].to_s

            gap["task_slug"].to_s.empty? || gap["task_slug"].to_s == item["task_slug"].to_s
          end
        end

        private

        def stringify_hash(value)
          value.to_h.each_with_object({}) { |(key, child), out| out[key.to_s] = child }
        rescue NoMethodError
          {}
        end
      end

      def initialize(projects:, starts_at:, ends_at:, prior_frontiers: {}, source_factory: nil,
                     observed_at: -> { Time.now.utc })
        @projects = Array(projects)
        @starts_at = starts_at
        @ends_at = ends_at
        @observed_at = observed_at
        @prior_frontiers = prior_frontiers.to_h
        @source_factory = source_factory || lambda do |project:, starts_at:, ends_at:, prior_frontier:|
          ProjectSource.new(project: project, starts_at: starts_at, ends_at: ends_at,
                            prior_frontier: prior_frontier,
                            observed_at: @observed_at)
        end
      end

      def collect
        projects = []
        facts = []
        attention = []
        gaps = []
        frontiers = {}
        project_id_counts = @projects.each_with_object(Hash.new(0)) do |project, counts|
          counts[stringify(project)["project_id"].to_s] += 1
        end
        @projects.each do |project|
          normalized = stringify(project)
          projects << normalized.slice("project_id", "registration_id", "name")
          frontier_key = self.class.frontier_key(normalized)
          begin
            result = @source_factory.call(
              project: normalized, starts_at: @starts_at, ends_at: @ends_at,
              prior_frontier: self.class.frontier_for(
                @prior_frontiers,
                project_id: normalized.fetch("project_id"),
                registration_id: normalized["registration_id"],
                allow_legacy: project_id_counts[normalized.fetch("project_id").to_s] == 1
              )
            ).collect
            facts.concat(result.facts)
            attention.concat(result.attention)
            gaps.concat(result.gaps)
            frontiers[frontier_key] = self.class.normalize_frontier(
              result.frontier, project: normalized
            )
          rescue ProjectSource::SourceUnavailable, SystemCallError, IOError => error
            gaps << Materiality.build_gap(
              source: "project_state", scope: normalized.fetch("name", "unknown"),
              reason_code: "source_unavailable",
              reason: bounded_reason(error), observed_at: @observed_at.call,
              project_id: normalized["project_id"],
              registration_id: normalized["registration_id"]
            )
          end
        end
        facts = facts.uniq { |fact| fact.fetch("fact_id") }
                     .sort_by { |fact| [ fact.fetch("occurred_at"), fact.fetch("fact_id") ] }
        gaps = gaps.uniq { |gap| gap.fetch("gap_id") }
                   .sort_by { |gap| [ gap.fetch("source"), gap.fetch("scope"), gap.fetch("gap_id") ] }
        completeness = gaps.empty? ? "complete" : "partial"
        content = if facts.any? || attention.any?
          "non_empty"
        elsif completeness == "partial"
          "unknown"
        else
          "empty"
        end
        Result.new(
          projects: projects.freeze, facts: facts.freeze, attention: attention.freeze,
          gaps: gaps.freeze, frontiers: frontiers.freeze,
          completeness: completeness, content: content
        )
      end

      private

      def stringify(value)
        value.to_h.each_with_object({}) { |(key, child), out| out[key.to_s] = child }
      end

      def bounded_reason(error)
        label = error.is_a?(ProjectSource::SourceUnavailable) ? error.message : error.class.name
        label.to_s.gsub(/[\u0000-\u001f\u007f]/, " ").byteslice(0, 240)
      end
    end
  end
end
