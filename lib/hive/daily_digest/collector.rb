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
        @projects.each do |project|
          normalized = stringify(project)
          projects << normalized.slice("project_id", "registration_id", "name")
          begin
            result = @source_factory.call(
              project: normalized, starts_at: @starts_at, ends_at: @ends_at,
              prior_frontier: @prior_frontiers[normalized.fetch("project_id")]
            ).collect
            facts.concat(result.facts)
            attention.concat(result.attention)
            gaps.concat(result.gaps)
            frontiers[normalized.fetch("project_id")] = result.frontier
          rescue ProjectSource::SourceUnavailable, SystemCallError, IOError => error
            gaps << Materiality.build_gap(
              source: "project_state", scope: normalized.fetch("name", "unknown"),
              reason_code: "source_unavailable",
              reason: bounded_reason(error), observed_at: @observed_at.call,
              project_id: normalized["project_id"]
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
