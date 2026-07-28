require "digest"
require "time"
require "hive/errors"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      module PatrolEvidence
        MODULES = %w[patrol architecture-patrol].freeze
        OWNERS = %w[legacy module].freeze
        AUTHORITIES = %w[legacy module shadow].freeze
        SINKS = %w[
          attempt state finding branch pull_request review_handoff
          job discovery action issue
        ].freeze
        RECEIPT_STATUSES = %w[
          attempted denied known_not_sent unknown committed reconciled failed
        ].freeze

        module_function

        def immutable_json(value, label:)
          case value
          when Hash
            value.each_with_object({}) do |(key, child), copy|
              malformed!(label) unless key.is_a?(String)
              copy[key.dup.freeze] = immutable_json(child, label: label)
            end.freeze
          when Array
            value.map { |child| immutable_json(child, label: label) }.freeze
          when String
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            malformed!(label) unless value.finite?
            value
          else
            malformed!(label)
          end
        end

        def timestamp(value, label:)
          time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
          time.utc.iso8601(6).freeze
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def digest(prefix, value)
          "#{prefix}-#{::Digest::SHA256.hexdigest(canonical(value))}".freeze
        end

        def nonempty(value, label:)
          string = value.to_s
          malformed!(label) if string.empty?
          string.dup.freeze
        end

        def positive_integer(value, label:)
          integer = Integer(value)
          malformed!(label) unless integer.positive?
          integer
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def optional_generation(value, label:)
          return nil if value.nil?

          generation = Integer(value)
          malformed!(label) if generation.negative?
          generation
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def exact_keys!(value, keys, label:)
          malformed!(label) unless value.is_a?(Hash) && value.keys.sort == keys.sort
          value
        end

        def enum(value, allowed, label:)
          string = value.to_s
          malformed!(label) unless allowed.include?(string)
          string.dup.freeze
        end

        def hex_id(value, prefix, label:)
          string = value.to_s
          malformed!(label) unless string.match?(/\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/)
          string.dup.freeze
        end

        def malformed!(label)
          raise Hive::ConfigError, "#{label} is malformed"
        end
      end

      class PatrolCaptureValidator
        KEYS = %w[
          capture_id decision decision_class effect_ids module occurred_at
          occurrence_id owner owner_epoch project recorded_at reservation
          schema schema_version trigger
        ].freeze
        PROJECT_KEYS = %w[name project_id repository].freeze

        class << self
          def build(module_name:, project:, trigger:, reservation:, owner:, owner_epoch:,
                    decision_class:, decision:, effect_ids: [], occurred_at:, recorded_at:)
            label = "patrol capture"
            module_name = PatrolEvidence.enum(module_name, PatrolEvidence::MODULES, label: label)
            owner = PatrolEvidence.enum(owner, PatrolEvidence::OWNERS, label: label)
            owner_epoch = PatrolEvidence.positive_integer(owner_epoch, label: label)
            project = project_value(project, label)
            trigger = object(trigger, label)
            reservation = object(reservation, label)
            decision = object(decision, label)
            decision_class = PatrolEvidence.nonempty(decision_class, label: label)
            effect_ids = Array(effect_ids).map do |effect_id|
              PatrolEvidence.nonempty(effect_id, label: label)
            end
            PatrolEvidence.malformed!(label) unless effect_ids.uniq == effect_ids
            effect_ids = effect_ids.freeze
            occurred_at = PatrolEvidence.timestamp(occurred_at, label: label)
            recorded_at = PatrolEvidence.timestamp(recorded_at, label: label)
            occurrence_identity = {
              "module" => module_name,
              "project" => project,
              "trigger" => trigger,
              "reservation" => reservation,
              "owner" => owner,
              "owner_epoch" => owner_epoch
            }
            occurrence_id = PatrolEvidence.digest("occ", occurrence_identity)
            capture_id = PatrolEvidence.digest(
              "cap",
              occurrence_identity.merge(
                "decision_class" => decision_class,
                "decision" => decision,
                "effect_ids" => effect_ids
              )
            )
            {
              capture_id: capture_id,
              module_name: module_name,
              occurrence_id: occurrence_id,
              project: project,
              trigger: trigger,
              reservation: reservation,
              owner: owner,
              owner_epoch: owner_epoch,
              decision_class: decision_class,
              decision: decision,
              effect_ids: effect_ids,
              occurred_at: occurred_at,
              recorded_at: recorded_at
            }
          end

          def parse(value)
            label = "patrol capture"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            PatrolEvidence.malformed!(label) unless value["schema"] == "hive-patrol-capture" &&
                                                    value["schema_version"] == 1
            attributes = build(
              module_name: value["module"],
              project: value["project"],
              trigger: value["trigger"],
              reservation: value["reservation"],
              owner: value["owner"],
              owner_epoch: value["owner_epoch"],
              decision_class: value["decision_class"],
              decision: value["decision"],
              effect_ids: value["effect_ids"],
              occurred_at: value["occurred_at"],
              recorded_at: value["recorded_at"]
            )
            unless attributes[:occurrence_id] == value["occurrence_id"] &&
                   attributes[:capture_id] == value["capture_id"]
              raise Hive::ConfigError, "patrol capture identity does not match its contents"
            end
            attributes
          end

          private

          def project_value(value, label)
            PatrolEvidence.exact_keys!(value, PROJECT_KEYS, label: label)
            project_id = PatrolEvidence.nonempty(value["project_id"], label: label)
            name = PatrolEvidence.nonempty(value["name"], label: label)
            repository = value["repository"]
            unless repository.nil?
              repository = PatrolEvidence.nonempty(repository, label: label)
            end
            { "project_id" => project_id, "name" => name, "repository" => repository }.freeze
          end

          def object(value, label)
            immutable = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.malformed!(label) unless immutable.is_a?(Hash)
            immutable
          end
        end
      end

      PatrolCapture = Data.define(
        :capture_id, :module_name, :occurrence_id, :project, :trigger,
        :reservation, :owner, :owner_epoch, :decision_class, :decision,
        :effect_ids, :occurred_at, :recorded_at
      ) do
        class << self
          def build(**attributes)
            new(**PatrolCaptureValidator.build(**attributes))
          end

          def from_h(value)
            new(**PatrolCaptureValidator.parse(value))
          end
        end

        def to_h
          {
            "schema" => "hive-patrol-capture",
            "schema_version" => 1,
            "capture_id" => capture_id,
            "module" => module_name,
            "occurrence_id" => occurrence_id,
            "project" => project,
            "trigger" => trigger,
            "reservation" => reservation,
            "owner" => owner,
            "owner_epoch" => owner_epoch,
            "decision_class" => decision_class,
            "decision" => decision,
            "effect_ids" => effect_ids,
            "occurred_at" => occurred_at,
            "recorded_at" => recorded_at
          }.freeze
        end
      end

      class EffectIntentValidator
        KEYS = %w[
          authority capability claim_generation created_at idempotency_key
          intent_id module occurrence_id owner_epoch sink target
        ].freeze

        class << self
          def build(module_name:, occurrence_id:, authority:, owner_epoch:, sink:, target:,
                    idempotency_key:, capability:, created_at:, claim_generation: nil)
            label = "patrol effect intent"
            module_name = PatrolEvidence.enum(module_name, PatrolEvidence::MODULES, label: label)
            occurrence_id = PatrolEvidence.hex_id(occurrence_id, "occ", label: label)
            authority = PatrolEvidence.enum(authority, PatrolEvidence::AUTHORITIES, label: label)
            owner_epoch = PatrolEvidence.positive_integer(owner_epoch, label: label)
            sink = PatrolEvidence.enum(sink, PatrolEvidence::SINKS, label: label)
            target = PatrolEvidence.nonempty(target, label: label)
            idempotency_key = PatrolEvidence.nonempty(idempotency_key, label: label)
            capability = PatrolEvidence.nonempty(capability, label: label)
            claim_generation = PatrolEvidence.optional_generation(claim_generation, label: label)
            created_at = PatrolEvidence.timestamp(created_at, label: label)
            identity = {
              "module" => module_name,
              "occurrence_id" => occurrence_id,
              "sink" => sink,
              "target" => target,
              "idempotency_key" => idempotency_key,
              "owner_epoch" => owner_epoch
            }
            {
              intent_id: PatrolEvidence.digest("intent", identity),
              module_name: module_name,
              occurrence_id: occurrence_id,
              authority: authority,
              owner_epoch: owner_epoch,
              sink: sink,
              target: target,
              idempotency_key: idempotency_key,
              capability: capability,
              claim_generation: claim_generation,
              created_at: created_at
            }
          end

          def parse(value)
            label = "patrol effect intent"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            attributes = build(
              module_name: value["module"],
              occurrence_id: value["occurrence_id"],
              authority: value["authority"],
              owner_epoch: value["owner_epoch"],
              sink: value["sink"],
              target: value["target"],
              idempotency_key: value["idempotency_key"],
              capability: value["capability"],
              claim_generation: value["claim_generation"],
              created_at: value["created_at"]
            )
            unless attributes[:intent_id] == value["intent_id"]
              raise Hive::ConfigError,
                    "patrol effect intent identity does not match its contents"
            end
            attributes
          end
        end
      end

      EffectIntent = Data.define(
        :intent_id, :module_name, :occurrence_id, :authority, :owner_epoch,
        :sink, :target, :idempotency_key, :capability, :claim_generation,
        :created_at
      ) do
        class << self
          def build(**attributes)
            new(**EffectIntentValidator.build(**attributes))
          end

          def from_h(value)
            new(**EffectIntentValidator.parse(value))
          end
        end

        def to_h
          {
            "intent_id" => intent_id,
            "module" => module_name,
            "occurrence_id" => occurrence_id,
            "authority" => authority,
            "owner_epoch" => owner_epoch,
            "sink" => sink,
            "target" => target,
            "idempotency_key" => idempotency_key,
            "capability" => capability,
            "claim_generation" => claim_generation,
            "created_at" => created_at
          }.freeze
        end
      end

      class EffectReceiptValidator
        KEYS = %w[intent outcome receipt_id recorded_at schema schema_version status].freeze

        class << self
          def build(intent:, status:, outcome:, recorded_at:)
            label = "patrol effect receipt"
            intent = intent.is_a?(EffectIntent) ? intent : EffectIntent.from_h(intent)
            status = PatrolEvidence.enum(status, PatrolEvidence::RECEIPT_STATUSES, label: label)
            outcome = PatrolEvidence.immutable_json(outcome, label: label)
            PatrolEvidence.malformed!(label) unless outcome.is_a?(Hash)
            recorded_at = PatrolEvidence.timestamp(recorded_at, label: label)
            receipt_id = PatrolEvidence.digest(
              "receipt",
              {
                "intent_id" => intent.intent_id,
                "status" => status,
                "outcome" => outcome
              }
            )
            {
              receipt_id: receipt_id,
              intent: intent,
              status: status,
              outcome: outcome,
              recorded_at: recorded_at
            }
          end

          def parse(value)
            label = "patrol effect receipt"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            PatrolEvidence.malformed!(label) unless value["schema"] == "hive-patrol-effect-receipt" &&
                                                    value["schema_version"] == 1
            attributes = build(
              intent: value["intent"],
              status: value["status"],
              outcome: value["outcome"],
              recorded_at: value["recorded_at"]
            )
            unless attributes[:receipt_id] == value["receipt_id"]
              raise Hive::ConfigError,
                    "patrol effect receipt identity does not match its contents"
            end
            attributes
          end
        end
      end

      EffectReceipt = Data.define(:receipt_id, :intent, :status, :outcome, :recorded_at) do
        class << self
          def build(**attributes)
            new(**EffectReceiptValidator.build(**attributes))
          end

          def from_h(value)
            new(**EffectReceiptValidator.parse(value))
          end
        end

        def to_h
          {
            "schema" => "hive-patrol-effect-receipt",
            "schema_version" => 1,
            "receipt_id" => receipt_id,
            "intent" => intent.to_h,
            "status" => status,
            "outcome" => outcome,
            "recorded_at" => recorded_at
          }.freeze
        end
      end
    end
  end
end
