require "hive/proposals"

module Hive
  module Proposals
    class Record
      KEYS = %w[
        schema schema_version proposal_id subject revision proposed_change motivation evidence
        author lineage provenance source_event_id created_at
      ].freeze
      LINEAGE_KEYS = %w[retries requested_supersedes].freeze

      attr_reader :data

      def self.build(proposal_id:, subject_kind:, subject_ref:, revision:, proposed_change:,
                     motivation:, evidence:, author:, provenance:, source_event_id:,
                     created_at: Time.now.utc, lineage: {}, policy: DEFAULT_POLICY)
        normalized_lineage = Proposals.stringify(lineage || {})
        normalized_lineage = {
          "retries" => normalized_lineage["retries"],
          "requested_supersedes" => normalized_lineage["requested_supersedes"]
        }
        new(
          "schema" => RECORD_SCHEMA, "schema_version" => SCHEMA_VERSION,
          "proposal_id" => Proposals.proposal_id!(proposal_id),
          "subject" => { "kind" => subject_kind.to_s, "reference" => subject_ref.to_s },
          "revision" => revision.to_s,
          "proposed_change" => Proposals.text!(proposed_change, label: "proposed_change"),
          "motivation" => Proposals.text!(motivation, label: "motivation"),
          "evidence" => Proposals.evidence!(evidence, policy:),
          "author" => Proposals.author!(author), "lineage" => normalized_lineage,
          "provenance" => Proposals.provenance!(provenance),
          "source_event_id" => Proposals.source_event_id!(source_event_id),
          "created_at" => Proposals.timestamp!(created_at, label: "created_at")
        )
      end

      def initialize(attributes)
        @data = Proposals.stringify(attributes)
        validate!
        @data = Proposals.deep_copy_freeze(@data)
        freeze
      end

      def [](key) = data[key.to_s]
      def to_h = JSON.parse(JSON.generate(data))
      def proposal_id = self["proposal_id"]
      def subject = self["subject"]
      def revision = self["revision"]
      def evidence = self["evidence"]
      def provenance = self["provenance"]
      def source_event_id = self["source_event_id"]
      def initial_status = "draft"

      private

      def validate!
        unless data.is_a?(Hash) && data.keys.sort == KEYS.sort &&
               data["schema"] == RECORD_SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "proposal record has an invalid or open schema envelope"
        end
        data["proposal_id"] = Proposals.proposal_id!(data["proposal_id"])
        subject = Proposals.closed_hash!(
          data["subject"], required: %w[kind reference], label: "proposal subject"
        )
        unless SUBJECT_KINDS.include?(subject["kind"])
          raise InvalidRecord, "proposal subject kind must be one of #{SUBJECT_KINDS.join(', ')}"
        end
        subject["reference"] = Proposals.subject_ref!(subject["reference"])
        data["subject"] = subject
        data["revision"] = Proposals.label!(data["revision"], label: "proposal revision")
        data["proposed_change"] = Proposals.text!(data["proposed_change"], label: "proposed_change")
        data["motivation"] = Proposals.text!(data["motivation"], label: "motivation")
        validate_evidence!
        data["author"] = Proposals.author!(data["author"])
        validate_lineage!
        data["provenance"] = Proposals.provenance!(data["provenance"])
        data["source_event_id"] = Proposals.source_event_id!(data["source_event_id"])
        data["created_at"] = Proposals.timestamp!(data["created_at"], label: "created_at")
      end

      def validate_evidence!
        unless data["evidence"].is_a?(Array) && !data["evidence"].empty?
          raise InvalidRecord, "proposal evidence must contain at least one item"
        end
        data["evidence"] = data["evidence"].map do |item|
          validate_persisted_evidence!(item)
        end
      end

      def validate_persisted_evidence!(item)
        required = %w[label digest bytes media_type visibility retention]
        evidence = Proposals.closed_hash!(
          item, required:, optional: %w[source_ref summary], label: "proposal evidence"
        )
        evidence["label"] = Proposals.label!(evidence["label"], label: "proposal evidence label")
        evidence["digest"] = Proposals.digest!(evidence["digest"], label: "proposal evidence digest")
        unless evidence["bytes"].is_a?(Integer) && evidence["bytes"] >= 0
          raise InvalidRecord, "proposal evidence bytes must be non-negative"
        end
        evidence["media_type"] = Proposals.label!(
          evidence["media_type"], label: "proposal evidence media_type"
        )
        unless VISIBILITIES.include?(evidence["visibility"])
          raise InvalidRecord, "proposal evidence visibility is invalid"
        end
        retention = Proposals.closed_hash!(
          evidence["retention"], required: %w[policy enforcement], label: "proposal retention"
        )
        unless RETENTIONS.include?(retention["policy"]) && retention["enforcement"] == "none"
          raise InvalidRecord, "proposal retention is invalid"
        end
        if evidence["summary"]
          unless evidence["visibility"] == "project"
            raise InvalidRecord, "non-project evidence cannot persist a summary"
          end
          evidence["summary"] = Proposals.text!(evidence["summary"], label: "proposal evidence summary")
        end
        evidence["source_ref"] = Proposals.safe_reference!(
          evidence["source_ref"], label: "proposal evidence source_ref"
        ) if evidence["source_ref"]
        evidence
      end

      def validate_lineage!
        lineage = Proposals.closed_hash!(data["lineage"], required: LINEAGE_KEYS, label: "proposal lineage")
        LINEAGE_KEYS.each do |key|
          next if lineage[key].nil?
          lineage[key] = Proposals.proposal_id!(lineage[key])
          raise InvalidRecord, "proposal cannot link to itself" if lineage[key] == proposal_id
        end
        data["lineage"] = lineage
      end
    end
  end
end
