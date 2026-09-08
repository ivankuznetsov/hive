require "json"
require "hive/proposals/query"

module Hive
  module Proposals
    ContextSelection = Data.define(
      :text, :items, :selected_ids, :digest, :configured_budget,
      :effective_budget, :truncated, :reason
    ) do
      def empty? = items.empty?

      def provenance
        {
          "configured_budget" => configured_budget,
          "effective_budget" => effective_budget,
          "selected_ids" => selected_ids,
          "selection_digest" => digest,
          "truncated" => truncated,
          "reason" => reason
        }
      end
    end

    # Selects instruction-free, closed typed facts for an attempt whose
    # proposal subject was durably admitted by the controller.
    class ContextSelector
      HEADER = "## Retained proposal facts (tracking only)\n".freeze

      def initialize(query:)
        @query = query
      end

      def select(context:, max_items:, max_bytes:, remaining_bytes:)
        configured_budget = positive_integer(max_bytes, "proposal context byte budget")
        max_items = positive_integer(max_items, "proposal context item budget")
        effective_budget = [ configured_budget, [ Integer(remaining_bytes), 0 ].max ].min
        subject = normalized_subject(context&.proposal_binding)
        return empty_selection(configured_budget, effective_budget, "unbound") unless subject

        result = @query.list(include_drafts: true)
        ranked = ranked_candidates(result.proposals, subject)
        if subject["proposal_id"] && ranked.none? { |rank, projection| rank.zero? && exact?(projection, subject) }
          return empty_selection(configured_budget, effective_budget, "stale_binding")
        end

        candidates = ranked.filter_map do |rank, projection|
          next unless projection.terminal?
          [ rank, typed_fact(projection) ]
        end.first(max_items)
        if candidates.empty?
          return empty_selection(configured_budget, effective_budget, "no_terminal_matches")
        end
        truncated = ranked.count { |_rank, projection| projection.terminal? } > candidates.length
        items = []
        lines = []
        bytes = HEADER.bytesize
        candidates.each do |_rank, item|
          line = "- #{JSON.generate(item)}\n"
          if bytes + line.bytesize > effective_budget
            truncated = true
            break
          end
          items << item
          lines << line
          bytes += line.bytesize
        end
        text = lines.empty? ? "" : HEADER + lines.join
        ids = items.map { |item| item.fetch("proposal_id") }
        digest = Proposals.digest(
          "items" => items, "configured_budget" => configured_budget,
          "effective_budget" => effective_budget, "truncated" => truncated
        )
        ContextSelection.new(
          text:, items:, selected_ids: ids, digest:, configured_budget:,
          effective_budget:, truncated:, reason: items.empty? ? "budget_exhausted" : "selected"
        )
      rescue InvalidRecord, ArgumentError, TypeError
        empty_selection(configured_budget || 0, effective_budget || 0, "invalid_binding")
      end

      private

      def positive_integer(value, label)
        number = Integer(value)
        raise ArgumentError, "#{label} must be positive" unless number.positive?
        number
      end

      def normalized_subject(binding)
        return nil unless binding.is_a?(Hash)
        raw = Proposals.stringify(binding).fetch("subject", nil)
        return nil unless raw.is_a?(Hash) && raw.keys.sort == %w[kind proposal_id reference revision]
        return nil unless SUBJECT_KINDS.include?(raw["kind"])

        subject = {
          "kind" => raw.fetch("kind"),
          "reference" => Proposals.subject_ref!(raw.fetch("reference")),
          "revision" => Proposals.label!(raw.fetch("revision"), label: "proposal context revision"),
          "proposal_id" => raw["proposal_id"] && Proposals.proposal_id!(raw["proposal_id"])
        }
        subject
      end

      def ranked_candidates(projections, subject)
        exact = projections.find { |projection| exact?(projection, subject) }
        related_ids = exact ? exact.lineage_ids : []
        projections.filter_map do |projection|
          rank = if exact?(projection, subject)
            0
          elsif related_ids.include?(projection.proposal_id) ||
                projection.lineage_ids.include?(subject["proposal_id"])
            1
          elsif same_subject?(projection, subject)
            2
          end
          [ rank, projection ] if rank
        end.sort_by do |rank, projection|
          [ rank, projection.record["created_at"], projection.proposal_id ]
        end
      end

      def exact?(projection, subject)
        return false unless same_subject?(projection, subject) && projection.revision == subject["revision"]
        subject["proposal_id"].nil? || projection.proposal_id == subject["proposal_id"]
      end

      def same_subject?(projection, subject)
        projection.subject == { "kind" => subject["kind"], "reference" => subject["reference"] }
      end

      def typed_fact(projection)
        evaluation_facts = projection.evaluations.map do |evaluation|
          {
            "evaluation_id" => evaluation.fetch("event_id"),
            "occurred_at" => evaluation.fetch("occurred_at"),
            "evaluator_id" => evaluation.dig("evaluator", "id"),
            "method_kind" => evaluation.dig("method", "kind"),
            "outcome" => evaluation.dig("result", "outcome"),
            "numeric_values" => numeric_values(evaluation.dig("result", "metrics")),
            "details_digest" => evaluation.dig("result", "details_digest")
          }
        end
        {
          "proposal_id" => projection.proposal_id,
          "subject_kind" => projection.subject.fetch("kind"),
          "status" => projection.status,
          "created_at" => projection.record["created_at"],
          "evaluations" => evaluation_facts,
          "lineage_ids" => projection.lineage_ids,
          "retention_enforcement" => "none"
        }
      end

      def numeric_values(metrics)
        return [] unless metrics.is_a?(Hash)

        metrics.keys.sort.filter_map do |key|
          value = metrics[key]
          value if value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
        end
      end

      def empty_selection(configured_budget, effective_budget, reason)
        digest = Proposals.digest(
          "items" => [], "configured_budget" => configured_budget,
          "effective_budget" => effective_budget, "truncated" => false, "reason" => reason
        )
        ContextSelection.new(
          text: "", items: [], selected_ids: [], digest:, configured_budget:,
          effective_budget:, truncated: false, reason:
        )
      end
    end
  end
end
