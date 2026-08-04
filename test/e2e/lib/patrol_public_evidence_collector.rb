require "digest"
require "hive/workflow_package/canonical_json"

module Hive
  module E2E
    # Independent oracle for receipts built from persisted shadow records.
    # It deliberately accepts hashes only: the qualification harness may read
    # production evidence, but it cannot construct captures or effect objects.
    class PatrolPublicEvidenceCollector
      Prepared = Data.define(:document, :bindings)

      def initialize(common:)
        @common = immutable(common)
      end

      def prepare(record:, repository:, decision_class:, fault_steps:,
                  generated_at:, reviewed_at:)
        capture = immutable(record.fetch("legacy_capture"))
        projection = immutable(record.fetch("module_decision"))
        effects = (
          record.fetch("legacy_effects") + record.fetch("module_effects")
        ).map { |effect| immutable(effect) }
         .sort_by { |effect| effect.fetch("receipt_id") }
        payload = {
          "schema" => "hive-patrol-evidence-receipt",
          "schema_version" => 1,
          "run_id" => @common.fetch("run_id"),
          "candidate_sha" => @common.fetch("candidate_sha"),
          "catalog_digest" => @common.fetch("catalog_digest"),
          "source_digest" => @common.fetch("source_digest"),
          "manifest_digest" => @common.fetch("manifest_digest"),
          "configuration_digest" => record.fetch("configuration_digest"),
          "scenario_manifest_digest" =>
            @common.fetch("scenario_manifest_digest"),
          "repository" => immutable(repository),
          "capture" => capture,
          "module_projection" => projection,
          "decision_class" => decision_class,
          "effects" => effects,
          "fault_steps" => immutable(fault_steps.sort),
          "artifacts" => @common.fetch("artifacts").sort_by do |artifact|
            [ artifact.fetch("kind"), artifact.fetch("digest") ]
          end,
          "reviewer" => @common.fetch("reviewer"),
          "generated_at" => generated_at,
          "reviewed_at" => reviewed_at
        }
        receipt_id = "evidence-#{Digest::SHA256.hexdigest(canonical(payload))}"
        document = immutable(payload.merge("receipt_id" => receipt_id))
        bindings = immutable(
          "run_id" => document.fetch("run_id"),
          "candidate_sha" => document.fetch("candidate_sha"),
          "catalog_digest" => document.fetch("catalog_digest"),
          "source_digest" => document.fetch("source_digest"),
          "manifest_digest" => document.fetch("manifest_digest"),
          "configuration_digest" => document.fetch("configuration_digest"),
          "scenario_manifest_digest" =>
            document.fetch("scenario_manifest_digest"),
          "repository" => document.fetch("repository"),
          "receipt_id" => receipt_id,
          "capture_id" => capture.fetch("capture_id"),
          "trigger_id" => capture.fetch("trigger").fetch("id"),
          "owner_epoch" => capture.fetch("owner_epoch"),
          "module_projection_digest" =>
            Digest::SHA256.hexdigest(canonical(projection)),
          "decision_class" => decision_class,
          "effect_receipt_ids" => effects.map do |effect|
            effect.fetch("receipt_id")
          end,
          "fault_steps" => document.fetch("fault_steps"),
          "artifacts" => document.fetch("artifacts"),
          "reviewer" => document.fetch("reviewer"),
          "generated_at" => generated_at,
          "reviewed_at" => reviewed_at
        )
        Prepared.new(document:, bindings:).freeze
      end

      def accept!(prepared, observed)
        unless canonical(prepared.document) == canonical(observed)
          raise "Patrol receipt diverged from the independent control"
        end

        prepared.document
      end

      private

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def immutable(value)
        case value
        when Hash
          value.to_h do |key, child|
            [ key.to_s.dup.freeze, immutable(child) ]
          end.freeze
        when Array then value.map { |child| immutable(child) }.freeze
        when String then value.dup.freeze
        else value.freeze
        end
      end
    end
  end
end
