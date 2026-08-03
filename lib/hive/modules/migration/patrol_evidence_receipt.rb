require "time"
require "hive/modules/migration/patrol_evidence"

module Hive
  module Modules
    module Migration
      class PatrolEvidenceReceipt < Data.define(
        :receipt_id, :run_id, :candidate_sha, :catalog_digest,
        :source_digest, :manifest_digest, :configuration_digest,
        :scenario_manifest_digest, :repository, :capture,
        :module_projection, :decision_class, :effects, :fault_steps,
        :artifacts, :reviewer, :generated_at, :reviewed_at
      )
        SCHEMA = "hive-patrol-evidence-receipt".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 256 * 1024
        MAX_ITEMS = 128
        MAX_LABEL_BYTES = 256
        MAX_CONTEXT_BYTES = 1_024
        KEYS = %w[
          artifacts candidate_sha capture catalog_digest configuration_digest
          decision_class effects fault_steps generated_at manifest_digest
          module_projection receipt_id repository reviewed_at reviewer run_id
          scenario_manifest_digest schema schema_version source_digest
        ].freeze
        REPOSITORY_KEYS = %w[change_window id sha].freeze
        ARTIFACT_KEYS = %w[digest kind].freeze

        class << self
          def build(run_id:, candidate_sha:, catalog_digest:, source_digest:,
                    manifest_digest:, configuration_digest:,
                    scenario_manifest_digest:, repository:, capture:,
                    module_projection:, decision_class:, effects:, fault_steps:,
                    artifacts:, reviewer:, generated_at:, reviewed_at:)
            label = "patrol evidence receipt"
            capture = coerce_capture(capture)
            projection = PatrolDecisionProjection.coerce(module_projection)
            repository = repository_value(repository, label)
            malformed! unless capture.owner == "legacy" &&
                              capture.outcome_class && capture.outcome &&
                              capture.module_name == projection.module_name &&
                              capture.selection.to_h == projection.to_h &&
                              (
                                capture.project.fetch("repository").nil? ||
                                  capture.project.fetch("repository") ==
                                    repository.fetch("id")
                              )

            effects = bounded_array(effects)
              .map { |value| coerce_effect(value) }
            effects.each do |effect|
              malformed! unless effect.intent.module_name == capture.module_name &&
                                effect.intent.occurrence_id == capture.occurrence_id &&
                                effect.intent.owner_epoch == capture.owner_epoch
            end
            effects = effects.sort_by(&:receipt_id)
            malformed! unless effects.map(&:receipt_id).uniq.size == effects.size
            committed = effects.select do |effect|
              effect.intent.authority == "legacy" &&
                %w[committed reconciled].include?(effect.status)
            end.map(&:receipt_id).sort
            malformed! unless capture.effect_ids.sort == committed

            fault_steps = string_set(fault_steps, label)
            artifacts = artifact_set(artifacts, label)
            generated_at = timestamp(generated_at, label)
            reviewed_at = timestamp(reviewed_at, label)
            malformed! if Time.iso8601(reviewed_at) < Time.iso8601(generated_at)

            attributes = {
              run_id: bounded_string(run_id, label, MAX_LABEL_BYTES),
              candidate_sha: sha(candidate_sha, label),
              catalog_digest: digest(catalog_digest, label),
              source_digest: digest(source_digest, label),
              manifest_digest: digest(manifest_digest, label),
              configuration_digest: digest(configuration_digest, label),
              scenario_manifest_digest: digest(
                scenario_manifest_digest, label
              ),
              repository: repository,
              capture: capture,
              module_projection: projection,
              decision_class: bounded_string(
                decision_class, label, MAX_LABEL_BYTES
              ),
              effects: effects.freeze,
              fault_steps: fault_steps,
              artifacts: artifacts,
              reviewer: bounded_string(reviewer, label, MAX_CONTEXT_BYTES),
              generated_at: generated_at,
              reviewed_at: reviewed_at
            }
            receipt_id = PatrolEvidence.digest(
              "evidence", payload(attributes)
            )
            PatrolEvidence.bounded!(
              payload(attributes, receipt_id: receipt_id),
              max_bytes: MAX_BYTES,
              label: label
            )
            new(receipt_id: receipt_id, **attributes)
          end

          def from_h(value)
            label = "patrol evidence receipt"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            malformed! unless value["schema"] == SCHEMA &&
                              value["schema_version"] == SCHEMA_VERSION
            receipt = build(
              run_id: value["run_id"],
              candidate_sha: value["candidate_sha"],
              catalog_digest: value["catalog_digest"],
              source_digest: value["source_digest"],
              manifest_digest: value["manifest_digest"],
              configuration_digest: value["configuration_digest"],
              scenario_manifest_digest: value["scenario_manifest_digest"],
              repository: value["repository"],
              capture: value["capture"],
              module_projection: value["module_projection"],
              decision_class: value["decision_class"],
              effects: value["effects"],
              fault_steps: value["fault_steps"],
              artifacts: value["artifacts"],
              reviewer: value["reviewer"],
              generated_at: value["generated_at"],
              reviewed_at: value["reviewed_at"]
            )
            unless receipt.receipt_id == value["receipt_id"] &&
                   canonical(receipt.to_h) == canonical(value)
              raise Hive::ConfigError,
                    "patrol evidence receipt identity does not match its contents"
            end
            receipt
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          def canonical(value)
            PatrolEvidence.canonical(
              value.is_a?(self) ? value.to_h : value
            )
          end

          private

          def payload(attributes, receipt_id: nil)
            {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "receipt_id" => receipt_id,
              "run_id" => attributes.fetch(:run_id),
              "candidate_sha" => attributes.fetch(:candidate_sha),
              "catalog_digest" => attributes.fetch(:catalog_digest),
              "source_digest" => attributes.fetch(:source_digest),
              "manifest_digest" => attributes.fetch(:manifest_digest),
              "configuration_digest" =>
                attributes.fetch(:configuration_digest),
              "scenario_manifest_digest" =>
                attributes.fetch(:scenario_manifest_digest),
              "repository" => attributes.fetch(:repository),
              "capture" => attributes.fetch(:capture).to_h,
              "module_projection" =>
                attributes.fetch(:module_projection).to_h,
              "decision_class" => attributes.fetch(:decision_class),
              "effects" => attributes.fetch(:effects).map(&:to_h),
              "fault_steps" => attributes.fetch(:fault_steps),
              "artifacts" => attributes.fetch(:artifacts),
              "reviewer" => attributes.fetch(:reviewer),
              "generated_at" => attributes.fetch(:generated_at),
              "reviewed_at" => attributes.fetch(:reviewed_at)
            }.tap { |result| result.delete("receipt_id") unless receipt_id }
          end

          def coerce_capture(value)
            value.is_a?(PatrolCapture) ?
              PatrolCapture.from_h(value.to_h) : PatrolCapture.from_h(value)
          rescue Hive::ConfigError
            malformed!
          end

          def coerce_effect(value)
            value.is_a?(EffectReceipt) ?
              EffectReceipt.from_h(value.to_h) : EffectReceipt.from_h(value)
          rescue Hive::ConfigError
            malformed!
          end

          def repository_value(value, label)
            PatrolEvidence.exact_keys!(value, REPOSITORY_KEYS, label: label)
            {
              "id" => bounded_string(
                value["id"], label, MAX_CONTEXT_BYTES
              ),
              "sha" => sha(value["sha"], label),
              "change_window" => bounded_string(
                value["change_window"], label, MAX_CONTEXT_BYTES
              )
            }.freeze
          end

          def artifact_set(values, label)
            artifacts = bounded_array(values).map do |value|
              PatrolEvidence.exact_keys!(value, ARTIFACT_KEYS, label: label)
              {
                "kind" => bounded_string(
                  value["kind"], label, MAX_LABEL_BYTES
                ),
                "digest" => digest(value["digest"], label)
              }.freeze
            end
            artifacts.sort_by! { |value| [ value.fetch("kind"), value.fetch("digest") ] }
            malformed! unless artifacts.uniq == artifacts
            artifacts.freeze
          end

          def string_set(values, label)
            strings = bounded_array(values).map do |value|
              bounded_string(value, label, MAX_LABEL_BYTES)
            end.sort
            malformed! if strings.uniq != strings
            strings.freeze
          end

          def bounded_array(value)
            value = array(value)
            malformed! if value.size > MAX_ITEMS
            value
          end

          def array(value)
            malformed! unless value.is_a?(Array)
            value
          end

          def bounded_string(value, label, max_bytes)
            string = nonempty(value, label)
            malformed! if string.bytesize > max_bytes
            string
          end

          def nonempty(value, label)
            PatrolEvidence.nonempty(value, label: label)
          end

          def timestamp(value, label)
            PatrolEvidence.timestamp(value, label: label)
          end

          def digest(value, label)
            string = value.to_s
            malformed! unless string.match?(/\A[0-9a-f]{64}\z/)
            string.dup.freeze
          end

          def sha(value, label)
            string = value.to_s
            malformed! unless string.match?(/\A[0-9a-f]{40}\z/)
            string.dup.freeze
          end

          def malformed!
            PatrolEvidence.malformed!("patrol evidence receipt")
          end
        end

        def to_h
          self.class.send(
            :payload,
            to_h_attributes,
            receipt_id: receipt_id
          ).freeze
        end

        private

        def to_h_attributes
          members.to_h { |name| [ name, public_send(name) ] }
        end
      end
    end
  end
end
