require "hive/proposals/store"

module Hive
  module Proposals
    QueryResult = Data.define(:proposals, :diagnostics, :filters, :digest) do
      def to_h
        {
          "proposals" => proposals.map(&:to_h),
          "diagnostics" => diagnostics.map(&:to_h),
          "filters" => filters,
          "result_digest" => digest
        }
      end
    end

    ShowResult = Data.define(:projection, :history, :diagnostics, :digest) do
      def to_h
        payload = projection.to_h.merge("history" => history.map(&:to_h))
        payload["diagnostics"] = diagnostics.map(&:to_h)
        payload["result_digest"] = digest
        payload
      end
    end

    # One live projection query used by the CLI and prompt-context selector.
    # Generated wiki files are deliberately never consulted here.
    class Query
      FILTERS = %w[kind subject revision status relation evaluator method].freeze

      def initialize(store:)
        @store = store
      end

      def list(filters: {}, include_drafts: false, include_diagnostics: false)
        filters = normalize_filters(filters)
        snapshot = @store.load
        proposals = snapshot.projections.select do |projection|
          (include_drafts || projection.terminal?) && matches?(projection, filters)
        end.sort_by { |projection| [ projection.subject.fetch("kind"), projection.subject.fetch("reference"),
                                     projection.revision, projection.proposal_id ] }
        diagnostics = include_diagnostics ? snapshot.diagnostics : []
        digest = Proposals.digest(
          "proposal_ids" => proposals.map(&:proposal_id),
          "projection_digests" => proposals.map { |projection| projection.to_h.fetch("projection_digest") },
          "diagnostics" => diagnostics.map(&:to_h), "filters" => filters
        )
        QueryResult.new(proposals:, diagnostics:, filters:, digest:)
      end

      def show(proposal_id, include_diagnostics: true)
        proposal_id = Proposals.proposal_id!(proposal_id)
        snapshot = @store.load
        projection = snapshot.projections.find { |candidate| candidate.proposal_id == proposal_id }
        raise InvalidRecord, "proposal is missing or quarantined" unless projection

        diagnostics = if include_diagnostics
          snapshot.diagnostics.select { |item| item.proposal_id.nil? || item.proposal_id == proposal_id }
        else
          []
        end
        history = projection.events.sort_by(&:version)
        digest = Proposals.digest(
          "projection" => projection.to_h, "history" => history.map(&:to_h),
          "diagnostics" => diagnostics.map(&:to_h)
        )
        ShowResult.new(projection:, history:, diagnostics:, digest:)
      end

      private

      def normalize_filters(value)
        data = Proposals.stringify(value || {})
        raise InvalidRecord, "proposal filters must be an object" unless data.is_a?(Hash)
        unknown = data.keys - FILTERS
        raise InvalidRecord, "unknown proposal filters: #{unknown.join(', ')}" unless unknown.empty?

        data.each_with_object({}) do |(key, raw), normalized|
          next if raw.nil? || raw.to_s.empty?
          normalized[key] = Proposals.label!(raw, label: "proposal #{key} filter")
        end.sort.to_h
      end

      def matches?(projection, filters)
        filters.all? do |key, expected|
          case key
          when "kind" then projection.subject.fetch("kind") == expected
          when "subject" then projection.subject.fetch("reference") == expected
          when "revision" then projection.revision == expected
          when "status" then projection.status == expected
          when "relation" then projection.lineage_ids.include?(expected)
          when "evaluator"
            projection.evaluations.any? { |evaluation| evaluation.dig("evaluator", "id") == expected }
          when "method"
            projection.evaluations.any? do |evaluation|
              method = evaluation.fetch("method")
              method["label"] == expected || method["kind"] == expected || method["reference"] == expected
            end
          end
        end
      end
    end
  end
end
