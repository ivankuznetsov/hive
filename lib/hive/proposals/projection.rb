require "hive/proposals/record"
require "hive/proposals/event"

module Hive
  module Proposals
    class Projection
      LIFECYCLE_TYPES = %w[decision supersession rollback].freeze

      attr_reader :record, :events, :evaluations, :decision, :superseded_by, :rollback,
                  :status, :lifecycle_head, :supersedes

      def self.empty_head_digest(proposal_id)
        Proposals.digest("proposal_id" => proposal_id, "lifecycle_events" => [])
      end

      def initialize(record:, events:, supersedes: [])
        @record = record.is_a?(Record) ? record : Record.new(record)
        @events = Array(events).map { |event| event.is_a?(Event) ? event : Event.new(event) }
                              .sort_by(&:version).freeze
        @supersedes = Array(supersedes).map { |id| Proposals.proposal_id!(id) }.uniq.sort.freeze
        validate_history!
        @evaluations = @events.select { |event| event.type == "evaluation" }.map do |event|
          event.data.merge(
            "event_id" => event.event_id, "version" => event.version,
            "source_event_id" => event.source_event_id,
            "occurred_at" => event.occurred_at, "provenance" => event.provenance
          )
        end.freeze
        decision_event = @events.find { |event| event.type == "decision" }
        supersession_event = @events.find { |event| event.type == "supersession" }
        rollback_event = @events.find { |event| event.type == "rollback" }
        @decision = decision_event&.data
        @superseded_by = supersession_event&.data&.fetch("successor_id")
        @rollback = rollback_event&.data
        @lifecycle_head = build_lifecycle_head.freeze
        @status = effective_status.freeze
        freeze
      end

      def proposal_id = record.proposal_id
      def subject = record.subject
      def revision = record.revision
      def draft? = status == "draft"
      def terminal? = !draft?

      def to_h
        result = {
          "proposal_id" => proposal_id,
          "subject" => record.subject,
          "revision" => record.revision,
          "proposed_change" => record["proposed_change"],
          "motivation" => record["motivation"],
          "evidence" => record.evidence,
          "author" => record["author"],
          "status" => status,
          "evaluations" => evaluations,
          "decision" => decision,
          "lineage" => {
            "retries" => record["lineage"]["retries"],
            "requested_supersedes" => record["lineage"]["requested_supersedes"],
            "supersedes" => supersedes,
            "superseded_by" => superseded_by
          },
          "rollback" => rollback,
          "lifecycle_head" => lifecycle_head,
          "retention" => retention_summary,
          "provenance" => record.provenance,
          "source_event_id" => record.source_event_id,
          "created_at" => record["created_at"],
          "event_count" => events.length
        }
        result["projection_digest"] = Proposals.digest(result)
        result
      end

      private

      def validate_history!
        unless events.all? { |event| event.proposal_id == record.proposal_id }
          raise InconsistentHistory, "proposal history contains an event for another proposal"
        end
        expected_versions = (1..events.length).to_a
        unless events.map(&:version) == expected_versions
          raise InconsistentHistory, "proposal event versions must be contiguous and unique"
        end
        EVENT_TYPES.each do |type|
          next if type == "evaluation"
          if events.count { |event| event.type == type } > 1
            raise InconsistentHistory, "proposal history contains multiple #{type} events"
          end
        end
        decision_event = events.find { |event| event.type == "decision" }
        if decision_event
          known = events.select { |event| event.type == "evaluation" && event.version < decision_event.version }
                        .to_h { |event| [ event.event_id, event ] }
          decision_event.data.fetch("considered_evaluation_ids").each do |event_id|
            raise InconsistentHistory, "decision references a missing evaluation" unless known.key?(event_id)
          end
        end
        rollback_event = events.find { |event| event.type == "rollback" }
        if rollback_event && decision_event&.data&.fetch("outcome") != "accepted"
          raise InconsistentHistory, "rollback requires historical acceptance"
        end
        if rollback_event && rollback_event.data.fetch("reverted_revision") != record.revision
          raise InconsistentHistory, "rollback revision does not match the candidate"
        end
      end

      def build_lifecycle_head
        lifecycle = events.select { |event| LIFECYCLE_TYPES.include?(event.type) }
        {
          "version" => lifecycle.last&.version || 0,
          "digest" => Proposals.digest(
            "proposal_id" => proposal_id,
            "lifecycle_events" => lifecycle.map(&:to_h)
          )
        }
      end

      def effective_status
        return "rolled_back" if rollback
        return "superseded" if superseded_by
        return decision.fetch("outcome") if decision

        "draft"
      end

      def retention_summary
        policies = record.evidence.map { |item| item.dig("retention", "policy") }.uniq.sort
        { "policies" => policies, "enforcement" => "none" }
      end
    end
  end
end
