require "hive/provider_health"

module Hive
  module ProviderHealth
    class Event
      FIELDS = %w[
        schema schema_version event_id sequence scope journal_epoch kind
        occurred_at idempotency_key expected_generation previous_generation
        resulting_generation payload
      ].freeze

      attr_reader :event_id, :sequence, :scope, :journal_epoch, :kind,
                  :occurred_at, :idempotency_key, :expected_generation,
                  :previous_generation, :resulting_generation, :payload

      def self.from_h(data)
        unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort &&
               data["schema"] == EVENT_SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise Unavailable, "provider-health journal event failed schema validation"
        end
        scope = ProviderHealth.scope_from_h(data.fetch("scope"))
        new(
          event_id: data.fetch("event_id"),
          sequence: data.fetch("sequence"),
          scope: scope,
          journal_epoch: data.fetch("journal_epoch"),
          kind: data.fetch("kind"),
          occurred_at: data.fetch("occurred_at"),
          idempotency_key: data.fetch("idempotency_key"),
          expected_generation: data.fetch("expected_generation"),
          previous_generation: data.fetch("previous_generation"),
          resulting_generation: data.fetch("resulting_generation"),
          payload: data.fetch("payload")
        )
      rescue KeyError, InvalidMutation, InvalidScope => e
        raise Unavailable, "provider-health journal event failed validation: #{e.class}"
      end

      def initialize(event_id:, sequence:, scope:, journal_epoch:, kind:, occurred_at:,
                     idempotency_key:, expected_generation:, previous_generation:,
                     resulting_generation:, payload:)
        raise InvalidMutation, "provider-health event requires a scope" unless scope.is_a?(Scope)
        kind_value = kind.to_s
        raise InvalidMutation, "unknown provider-health event kind" unless EVENT_KINDS.include?(kind_value)

        @event_id = ProviderHealth.identifier(event_id, "event")
        @sequence = positive_integer(sequence, "event sequence")
        @scope = scope
        @journal_epoch = ProviderHealth.nonnegative_integer(journal_epoch, "journal epoch")
        @kind = kind_value.freeze
        @occurred_at = ProviderHealth.parse_time(occurred_at, "event time").iso8601(6).freeze
        @idempotency_key = validate_digest(idempotency_key, "idempotency key")
        @expected_generation = ProviderHealth.nonnegative_integer(
          expected_generation, "expected generation"
        )
        @previous_generation = ProviderHealth.nonnegative_integer(
          previous_generation, "previous generation"
        )
        @resulting_generation = ProviderHealth.nonnegative_integer(
          resulting_generation, "resulting generation"
        )
        @payload = ProviderHealth.deep_freeze(ProviderHealth.deep_copy(payload))
        validate_generation!
        validate_payload!
        freeze
      end

      def mutating? = MUTATING_EVENT_KINDS.include?(kind)

      def apply(circuit)
        unless circuit.is_a?(Circuit) && circuit.scope == scope &&
               circuit.journal_epoch == journal_epoch &&
               circuit.generation == previous_generation
          raise Unavailable, "provider-health journal generation or scope gap"
        end

        changes = {
          generation: resulting_generation,
          last_event_id: event_id
        }
        validate_source_transition!(circuit)
        case kind
        when "evidence_opened"
          changes.merge!(
            automatic_state: "open",
            eligible_at: payload.fetch("eligible_at"),
            evidence: payload.fetch("evidence"),
            probe: nil
          )
        when "probe_claimed"
          changes[:probe] = payload.fetch("probe")
        when "probe_closed"
          changes.merge!(automatic_state: "closed", eligible_at: nil, evidence: nil, probe: nil)
        when "probe_reopened", "probe_reconciled"
          changes.merge!(
            automatic_state: "open",
            eligible_at: payload.fetch("eligible_at"),
            probe: nil
          )
        when "manual_blocked"
          changes.merge!(manual_block: payload.fetch("manual_block"), probe: nil)
        when "manual_unblocked"
          changes.merge!(manual_block: nil, probe: nil)
        when "reset"
          changes.merge!(
            automatic_state: "closed",
            eligible_at: nil,
            evidence: nil,
            probe: nil,
            manual_block: payload.fetch("manual_block")
          )
        when "snapshot"
          state = payload.fetch("state")
          changes.merge!(
            automatic_state: state.fetch("automatic_state"),
            eligible_at: state.fetch("eligible_at"),
            evidence: state.fetch("evidence"),
            manual_block: state.fetch("manual_block"),
            probe: state.fetch("probe"),
            last_event_id: state.fetch("last_event_id")
          )
        when "evidence_rejected"
          nil
        end
        circuit.with(**changes)
      end

      def to_h
        {
          "schema" => EVENT_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "event_id" => event_id,
          "sequence" => sequence,
          "scope" => scope.to_h,
          "journal_epoch" => journal_epoch,
          "kind" => kind,
          "occurred_at" => occurred_at,
          "idempotency_key" => idempotency_key,
          "expected_generation" => expected_generation,
          "previous_generation" => previous_generation,
          "resulting_generation" => resulting_generation,
          "payload" => payload
        }.freeze
      end

      private

      def positive_integer(value, label)
        number = Integer(value)
        raise InvalidMutation, "#{label} must be positive" unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise InvalidMutation, "#{label} must be a positive integer"
      end

      def validate_digest(value, label)
        string = value.to_s
        raise InvalidMutation, "#{label} must be lowercase SHA-256" unless SHA256_PATTERN.match?(string)

        string.freeze
      end

      def validate_generation!
        unless expected_generation == previous_generation
          raise InvalidMutation, "event expected and previous generations must match"
        end
        delta = mutating? ? 1 : 0
        unless resulting_generation == previous_generation + delta
          raise InvalidMutation, "event resulting generation violates transition semantics"
        end
      end

      def validate_payload!
        raise InvalidMutation, "provider-health event payload must be an object" unless payload.is_a?(Hash)

        required = case kind
        when "evidence_opened" then %w[evidence eligible_at]
        when "probe_claimed" then %w[probe]
        when "probe_closed" then %w[receipt_identity]
        when "probe_reopened", "probe_reconciled" then %w[eligible_at receipt_identity]
        when "manual_blocked" then %w[audit manual_block]
        when "manual_unblocked", "reset" then %w[audit manual_block]
        when "evidence_rejected" then %w[reason]
        when "snapshot" then %w[state]
        end
        unless payload.keys.sort == required.sort
          raise InvalidMutation, "provider-health event payload has unexpected fields"
        end


        case kind
        when "evidence_opened"
          Evidence.from_h(payload.fetch("evidence"))
          ProviderHealth.parse_time(payload.fetch("eligible_at"), "eligible_at")
        when "probe_claimed"
          binding = validate_probe!(payload.fetch("probe"))
          unless binding.scope == scope && binding.journal_epoch == journal_epoch &&
                 binding.observed_generation == previous_generation &&
                 binding.claim_generation == resulting_generation
            raise InvalidMutation, "probe binding does not match its journal transition"
          end
        when "probe_closed"
          validate_digest(payload.fetch("receipt_identity"), "receipt identity")
        when "probe_reopened", "probe_reconciled"
          ProviderHealth.parse_time(payload.fetch("eligible_at"), "eligible_at")
          validate_digest(payload.fetch("receipt_identity"), "receipt identity")
        when "manual_blocked"
          validate_manual_block!(payload.fetch("manual_block"))
          audit = validate_audit!(payload.fetch("audit"))
          block = payload.fetch("manual_block")
          unless block.fetch("actor") == audit.actor &&
                 block.fetch("reason") == audit.reason &&
                 block.fetch("blocked_at") == audit.occurred_at
            raise InvalidMutation, "manual block and audit identities do not match"
          end
        when "manual_unblocked", "reset"
          validate_manual_block!(payload.fetch("manual_block")) if payload.fetch("manual_block")
          validate_audit!(payload.fetch("audit"))
        when "evidence_rejected"
          unless %w[stale_generation fenced_attempt superseded_generation late_receipt].include?(
            payload.fetch("reason")
          )
            raise InvalidMutation, "invalid evidence rejection reason"
          end
        when "snapshot"
          validate_snapshot!(payload.fetch("state"))
        end
      end

      def validate_snapshot!(data)
        fields = %w[automatic_state eligible_at evidence last_event_id manual_block probe]
        unless data.is_a?(Hash) && data.keys.sort == fields.sort
          raise InvalidMutation, "provider-health snapshot has unexpected fields"
        end
        Circuit.new(
          scope: scope,
          automatic_state: data.fetch("automatic_state"),
          generation: previous_generation,
          journal_epoch: journal_epoch,
          eligible_at: data.fetch("eligible_at"),
          evidence: data.fetch("evidence"),
          manual_block: data.fetch("manual_block"),
          probe: data.fetch("probe"),
          last_event_id: data.fetch("last_event_id")
        )
      end

      def validate_source_transition!(circuit)
        case kind
        when "probe_claimed"
          occurred = ProviderHealth.parse_time(occurred_at, "event time")
          eligible = circuit.eligible_at &&
            ProviderHealth.parse_time(circuit.eligible_at, "eligible_at")
          unless circuit.automatic_state == "open" && !circuit.blocked? &&
                 !circuit.probe_owned? && eligible && occurred >= eligible
            raise Unavailable, "provider-health journal probe claim has no eligible source"
          end
        when "probe_closed", "probe_reopened", "probe_reconciled"
          unless circuit.probe_owned?
            raise Unavailable, "provider-health journal probe outcome has no owner"
          end
        end
      end

      def validate_probe!(data)
        fields = %w[
          scope journal_epoch observed_generation claim_generation attempt_id
          task_generation ownership_fence
        ]
        unless data.is_a?(Hash) && data.keys.sort == fields.sort
          raise InvalidMutation, "probe payload has unexpected fields"
        end
        binding_scope = ProviderHealth.scope_from_h(data.fetch("scope"))
        ProbeBinding.new(
          scope: binding_scope,
          journal_epoch: data.fetch("journal_epoch"),
          observed_generation: data.fetch("observed_generation"),
          claim_generation: data.fetch("claim_generation"),
          attempt_id: data.fetch("attempt_id"),
          task_generation: data.fetch("task_generation"),
          ownership_fence: data.fetch("ownership_fence")
        )
      end

      def validate_manual_block!(data)
        unless data.is_a?(Hash) && data.keys.sort == %w[actor blocked_at reason]
          raise InvalidMutation, "manual block payload has unexpected fields"
        end
        Audit.validate_actor(data.fetch("actor"))
        Audit.validate_reason(data.fetch("reason"))
        ProviderHealth.parse_time(data.fetch("blocked_at"), "blocked_at")
      end

      def validate_audit!(data)
        receipt = Audit::Receipt.from_h(data)
        target_scope = receipt.target
        raise InvalidMutation, "audit target does not match event scope" unless target_scope == scope
        expected_action = {
          "manual_blocked" => "block",
          "manual_unblocked" => "unblock",
          "reset" => "reset"
        }.fetch(kind)
        unless receipt.action == expected_action && receipt.event_id == event_id &&
               receipt.generation == resulting_generation
          raise InvalidMutation, "operator audit does not match its journal transition"
        end
        receipt
      end
    end
  end
end
