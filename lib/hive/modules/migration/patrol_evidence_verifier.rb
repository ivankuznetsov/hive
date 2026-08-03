require "digest"
require "hive/modules/migration/patrol_evidence_receipt"

module Hive
  module Modules
    module Migration
      module PatrolEvidenceVerifier
        EXPECTED_KEYS = %w[
          artifacts candidate_sha capture_id catalog_digest
          configuration_digest decision_class effect_receipt_ids generated_at
          fault_steps manifest_digest module_projection_digest owner_epoch
          repository reviewed_at reviewer run_id scenario_manifest_digest
          source_digest trigger_id
        ].freeze

        VerifiedReceipt = Data.define(:receipt, :binding_digest) do
          class << self
            private :new, :[]
          end

          def capture = receipt.capture
          def effects = receipt.effects
        end

        module_function

        def verify(receipt:, expected_bindings:)
          receipt = receipt.is_a?(PatrolEvidenceReceipt) ?
            PatrolEvidenceReceipt.from_h(receipt.to_h) :
            PatrolEvidenceReceipt.from_h(receipt)
          expected = normalized_expected(expected_bindings)
          observed = observed_bindings(receipt)
          unless PatrolEvidence.canonical(expected) ==
                 PatrolEvidence.canonical(observed)
            raise Hive::ConfigError,
                  "patrol evidence receipt does not match expected bindings"
          end

          VerifiedReceipt.send(
            :new,
            receipt: receipt,
            binding_digest: PatrolEvidence.digest("binding", observed)
          )
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        def observed_bindings(receipt)
          {
            "run_id" => receipt.run_id,
            "candidate_sha" => receipt.candidate_sha,
            "catalog_digest" => receipt.catalog_digest,
            "source_digest" => receipt.source_digest,
            "manifest_digest" => receipt.manifest_digest,
            "configuration_digest" => receipt.configuration_digest,
            "scenario_manifest_digest" => receipt.scenario_manifest_digest,
            "repository" => receipt.repository,
            "capture_id" => receipt.capture.capture_id,
            "trigger_id" => receipt.capture.trigger.fetch("id"),
            "owner_epoch" => receipt.capture.owner_epoch,
            "module_projection_digest" => ::Digest::SHA256.hexdigest(
              PatrolEvidence.canonical(receipt.module_projection.to_h)
            ),
            "decision_class" => receipt.decision_class,
            "effect_receipt_ids" =>
              receipt.effects.map(&:receipt_id).sort.freeze,
            "fault_steps" => receipt.fault_steps,
            "artifacts" => receipt.artifacts,
            "reviewer" => receipt.reviewer,
            "generated_at" => receipt.generated_at,
            "reviewed_at" => receipt.reviewed_at
          }.freeze
        end
        private_class_method :observed_bindings

        def normalized_expected(value)
          label = "patrol evidence expected bindings"
          value = PatrolEvidence.immutable_json(value, label: label)
          PatrolEvidence.exact_keys!(value, EXPECTED_KEYS, label: label)
          value = value.merge(
            "effect_receipt_ids" => normalized_ids(
              value.fetch("effect_receipt_ids"), "receipt"
            ),
            "fault_steps" => normalized_strings(value.fetch("fault_steps")),
            "artifacts" => normalized_artifacts(value.fetch("artifacts"))
          ).freeze
          value
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end
        private_class_method :normalized_expected

        def normalized_ids(value, prefix)
          values = normalized_strings(value)
          malformed! unless values.all? do |item|
            item.match?(/\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/)
          end
          values
        end
        private_class_method :normalized_ids

        def normalized_strings(value)
          malformed! unless value.is_a?(Array)
          values = value.map do |item|
            PatrolEvidence.nonempty(
              item, label: "patrol evidence expected bindings"
            )
          end.sort
          malformed! unless values.uniq == values
          values.freeze
        end
        private_class_method :normalized_strings

        def normalized_artifacts(value)
          malformed! unless value.is_a?(Array)
          artifacts = value.map do |item|
            PatrolEvidence.exact_keys!(
              item, PatrolEvidenceReceipt::ARTIFACT_KEYS,
              label: "patrol evidence expected bindings"
            )
            kind = PatrolEvidence.nonempty(
              item["kind"], label: "patrol evidence expected bindings"
            )
            digest = item["digest"].to_s
            malformed! unless digest.match?(/\A[0-9a-f]{64}\z/)
            { "kind" => kind, "digest" => digest.freeze }.freeze
          end.sort_by { |item| [ item.fetch("kind"), item.fetch("digest") ] }
          malformed! unless artifacts.uniq == artifacts
          artifacts.freeze
        end
        private_class_method :normalized_artifacts

        def malformed!
          raise Hive::ConfigError,
                "patrol evidence expected bindings are malformed"
        end
        private_class_method :malformed!
      end
    end
  end
end
