require "hive/proposals"

module Hive
  module Proposals
    class Event
      KEYS = %w[
        schema schema_version event_id proposal_id version type data source_event_id provenance
        policy occurred_at
      ].freeze
      DATA_KEYS = {
        "evaluation" => %w[evaluator method result rationale evidence links],
        "decision" => %w[
          outcome considered_evaluation_ids considered_evaluations rationale_category rationale
          authority links observed_head
        ],
        "supersession" => %w[successor_id authority observed_head],
        "rollback" => %w[reverted_revision reason external_revert authority observed_head]
      }.freeze

      attr_reader :attributes

      def self.build(event_id:, proposal_id:, version:, type:, data:, source_event_id:, provenance:,
                     occurred_at: Time.now.utc, policy: DEFAULT_POLICY)
        normalized_policy = Proposals.policy!(policy)
        event_data = normalize_data(type.to_s, data, policy: normalized_policy, admission: true)
        new(
          "schema" => EVENT_SCHEMA, "schema_version" => SCHEMA_VERSION,
          "event_id" => Proposals.event_id!(event_id),
          "proposal_id" => Proposals.proposal_id!(proposal_id, error: InvalidEvent),
          "version" => Integer(version), "type" => type.to_s, "data" => event_data,
          "source_event_id" => Proposals.source_event_id!(source_event_id, error: InvalidEvent),
          "provenance" => Proposals.provenance!(provenance, error: InvalidEvent),
          "policy" => normalized_policy,
          "occurred_at" => Proposals.timestamp!(occurred_at, label: "occurred_at", error: InvalidEvent)
        )
      rescue ArgumentError, TypeError
        raise InvalidEvent, "proposal event version must be a positive integer"
      end

      def self.normalize_data(type, value, policy: DEFAULT_POLICY, admission: false)
        required = DATA_KEYS[type]
        raise InvalidEvent, "unknown proposal event type #{type.inspect}" unless required

        data = Proposals.closed_hash!(
          value, required:, label: "proposal #{type} data", error: InvalidEvent
        )
        case type
        when "evaluation" then normalize_evaluation(data, policy:, admission:)
        when "decision" then normalize_decision(data, policy:)
        when "supersession" then normalize_supersession(data)
        when "rollback" then normalize_rollback(data, policy:)
        end
      end

      def self.normalize_evaluation(data, policy:, admission:)
        evaluator = Proposals.closed_hash!(
          data["evaluator"], required: %w[id binding_fingerprint],
          optional: %w[configuration_fingerprint], label: "proposal evaluator", error: InvalidEvent
        )
        evaluator["id"] = Proposals.label!(evaluator["id"], label: "evaluator id", error: InvalidEvent)
        %w[binding_fingerprint configuration_fingerprint].each do |key|
          evaluator[key] = Proposals.digest!(
            evaluator[key], label: "evaluator #{key}", error: InvalidEvent
          ) if evaluator[key]
        end
        facts = Proposals.evaluation_facts!(
          data.slice(*EVALUATION_FACT_KEYS), policy:, error: InvalidEvent, admission:
        )
        data.merge(facts).merge("evaluator" => evaluator)
      end

      def self.normalize_decision(data, policy:)
        outcome = data["outcome"].to_s
        raise InvalidEvent, "proposal decision outcome is invalid" unless %w[accepted rejected].include?(outcome)
        ids = Array(data["considered_evaluation_ids"]).map do |id|
          Proposals.event_id!(id, error: InvalidEvent)
        end
        raise InvalidEvent, "considered evaluation ids must be unique" unless ids.uniq == ids
        snapshots = Array(data["considered_evaluations"]).map do |item|
          snapshot = Proposals.closed_hash!(
            item,
            required: %w[evaluation_id evaluator_id method outcome result_digest],
            label: "considered evaluation", error: InvalidEvent
          )
          snapshot["evaluation_id"] = Proposals.event_id!(snapshot["evaluation_id"], error: InvalidEvent)
          snapshot["evaluator_id"] = Proposals.label!(snapshot["evaluator_id"], label: "evaluator id", error: InvalidEvent)
          snapshot["method"] = Proposals.label!(snapshot["method"], label: "method", error: InvalidEvent)
          unless RESULT_OUTCOMES.include?(snapshot["outcome"])
            raise InvalidEvent, "considered evaluation outcome is invalid"
          end
          snapshot["result_digest"] = Proposals.digest!(
            snapshot["result_digest"], label: "considered result digest", error: InvalidEvent
          )
          snapshot
        end
        unless snapshots.map { |item| item["evaluation_id"] } == ids
          raise InvalidEvent, "considered evaluation snapshots must match their ids"
        end
        category = data["rationale_category"].to_s
        if ids.empty?
          unless outcome == "rejected" && category == "no_evaluation"
            raise InvalidEvent, "no_evaluation is allowed only for an unevaluated rejection"
          end
        elsif category != "evaluated"
          raise InvalidEvent, "evaluated decisions require the evaluated rationale category"
        end
        data.merge(
          "outcome" => outcome, "considered_evaluation_ids" => ids,
          "considered_evaluations" => snapshots,
          "rationale" => Proposals.text!(data["rationale"], label: "decision rationale", error: InvalidEvent),
          "authority" => authority!(data["authority"]),
          "links" => Proposals.links!(
            data["links"], allowed_schemes: policy.fetch("allowed_link_schemes"),
            error: InvalidEvent
          ),
          "observed_head" => observed_head!(data["observed_head"])
        )
      end

      def self.normalize_supersession(data)
        data.merge(
          "successor_id" => Proposals.proposal_id!(data["successor_id"], error: InvalidEvent),
          "authority" => authority!(data["authority"]),
          "observed_head" => observed_head!(data["observed_head"])
        )
      end

      def self.normalize_rollback(data, policy:)
        external = Proposals.closed_hash!(
          data["external_revert"], required: %w[kind reference],
          label: "external revert", error: InvalidEvent
        )
        external["kind"] = Proposals.label!(external["kind"], label: "external revert kind", error: InvalidEvent)
        external["reference"] = Proposals.safe_reference!(
          external["reference"], label: "external revert reference",
          allowed_schemes: policy.fetch("allowed_link_schemes"), error: InvalidEvent
        )
        data.merge(
          "reverted_revision" => Proposals.label!(
            data["reverted_revision"], label: "reverted revision", error: InvalidEvent
          ),
          "reason" => Proposals.text!(data["reason"], label: "rollback reason", error: InvalidEvent),
          "external_revert" => external, "authority" => authority!(data["authority"]),
          "observed_head" => observed_head!(data["observed_head"])
        )
      end

      def self.authority!(value)
        data = Proposals.closed_hash!(
          value, required: %w[id kind policy_fingerprint],
          label: "proposal authority", error: InvalidEvent
        )
        data["id"] = Proposals.label!(data["id"], label: "authority id", error: InvalidEvent)
        unless %w[operator policy].include?(data["kind"])
          raise InvalidEvent, "proposal authority kind is invalid"
        end
        data["policy_fingerprint"] = Proposals.digest!(
          data["policy_fingerprint"], label: "authority policy fingerprint", error: InvalidEvent
        )
        data
      end

      def self.observed_head!(value)
        data = Proposals.closed_hash!(
          value, required: %w[version digest], label: "observed lifecycle head", error: InvalidEvent
        )
        unless data["version"].is_a?(Integer) && data["version"] >= 0
          raise InvalidEvent, "observed lifecycle head version is invalid"
        end
        data["digest"] = Proposals.digest!(
          data["digest"], label: "observed lifecycle head digest", error: InvalidEvent
        )
        data
      end

      def initialize(attributes)
        @attributes = Proposals.stringify(attributes)
        validate!
        @attributes = Proposals.deep_copy_freeze(@attributes)
        freeze
      end

      def [](key) = attributes[key.to_s]
      def to_h = JSON.parse(JSON.generate(attributes))
      def event_id = self["event_id"]
      def proposal_id = self["proposal_id"]
      def version = self["version"]
      def type = self["type"]
      def data = self["data"]
      def source_event_id = self["source_event_id"]
      def provenance = self["provenance"]
      def policy = self["policy"]
      def occurred_at = self["occurred_at"]

      private

      def validate!
        unless attributes.is_a?(Hash) && attributes.keys.sort == KEYS.sort &&
               attributes["schema"] == EVENT_SCHEMA && attributes["schema_version"] == SCHEMA_VERSION
          raise InvalidEvent, "proposal event has an invalid or open schema envelope"
        end
        attributes["event_id"] = Proposals.event_id!(attributes["event_id"])
        attributes["proposal_id"] = Proposals.proposal_id!(attributes["proposal_id"], error: InvalidEvent)
        unless attributes["version"].is_a?(Integer) && attributes["version"].positive?
          raise InvalidEvent, "proposal event version must be a positive integer"
        end
        attributes["policy"] = Proposals.policy!(attributes["policy"])
        attributes["data"] = self.class.normalize_data(
          attributes["type"], attributes["data"], policy: attributes["policy"]
        )
        attributes["source_event_id"] = Proposals.source_event_id!(
          attributes["source_event_id"], error: InvalidEvent
        )
        attributes["provenance"] = Proposals.provenance!(attributes["provenance"], error: InvalidEvent)
        attributes["occurred_at"] = Proposals.timestamp!(
          attributes["occurred_at"], label: "occurred_at", error: InvalidEvent
        )
      end
    end
  end
end
