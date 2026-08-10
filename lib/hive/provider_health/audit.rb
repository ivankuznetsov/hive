require "hive/provider_health"
require "hive/attempts/output_reference"

module Hive
  module ProviderHealth
    module Audit
      SECRET_PATTERN = /(?:bearer\s+|api[_-]?key|access[_-]?token|password|passwd|credential|private[_-]?key|secret\s*[:=])/i
      STATE_FIELDS = %w[
        automatic_state manual_blocked probe_owned generation journal_epoch
      ].freeze

      Receipt = Data.define(
        :actor, :reason, :target, :action, :occurred_at,
        :previous_state, :new_state, :generation, :event_id, :artifact_reference
      ) do
        def self.from_h(data)
          fields = %w[
            action actor artifact_reference event_id generation new_state
            occurred_at previous_state reason target
          ]
          unless data.is_a?(Hash) && data.keys.sort == fields.sort
            raise InvalidMutation, "audit receipt has unexpected fields"
          end
          new(
            actor: data.fetch("actor"),
            reason: data.fetch("reason"),
            target: ProviderHealth.scope_from_h(data.fetch("target")),
            action: data.fetch("action"),
            occurred_at: data.fetch("occurred_at"),
            previous_state: data.fetch("previous_state"),
            new_state: data.fetch("new_state"),
            generation: data.fetch("generation"),
            event_id: data.fetch("event_id"),
            artifact_reference: data.fetch("artifact_reference")
          )
        rescue KeyError
          raise InvalidMutation, "audit receipt is incomplete"
        end

        def initialize(actor:, reason:, target:, action:, occurred_at:, previous_state:,
                       new_state:, generation:, event_id:, artifact_reference: nil)
          action_value = action.to_s
          unless %w[block unblock reset].include?(action_value)
            raise InvalidMutation, "operator audit action is invalid"
          end
          super(
            actor: Audit.validate_actor(actor),
            reason: Audit.validate_reason(reason),
            target: target,
            action: action_value.freeze,
            occurred_at: ProviderHealth.parse_time(occurred_at, "audit time").iso8601(6).freeze,
            previous_state: Audit.validate_state(previous_state),
            new_state: Audit.validate_state(new_state),
            generation: ProviderHealth.nonnegative_integer(generation, "audit generation"),
            event_id: ProviderHealth.identifier(event_id, "event"),
            artifact_reference: Audit.validate_reference(artifact_reference)
          )
          freeze
        end

        def to_h
          {
            "actor" => actor,
            "reason" => reason,
            "target" => target.to_h,
            "action" => action,
            "occurred_at" => occurred_at,
            "previous_state" => previous_state,
            "new_state" => new_state,
            "generation" => generation,
            "event_id" => event_id,
            "artifact_reference" => artifact_reference
          }.freeze
        end
      end

      module_function

      def validate_actor(value)
        string = value.to_s
        unless value.is_a?(String) && !string.empty? && string.bytesize <= MAX_ACTOR_BYTES &&
               string.valid_encoding? && !string.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidMutation, "operator actor identity is invalid"
        end
        string.dup.freeze
      end

      def validate_reason(value)
        string = value.to_s
        unless value.is_a?(String) && !string.strip.empty? &&
               string.bytesize <= MAX_REASON_BYTES && string.valid_encoding?
          raise InvalidMutation, "operator reason must be bounded non-empty UTF-8"
        end
        if string.match?(/[\u0000-\u001f\u007f]/) || string.include?("\n") || string.include?("\r")
          raise InvalidMutation, "operator reason must be one line without control characters"
        end
        if SECRET_PATTERN.match?(string)
          raise InvalidMutation, "operator reason resembles credential material"
        end
        string.dup.freeze
      end

      def validate_state(value)
        unless value.is_a?(Hash) && value.keys.map(&:to_s).sort == STATE_FIELDS.sort
          raise InvalidMutation, "audit state must contain only typed circuit metadata"
        end
        normalized = value.to_h { |key, child| [ key.to_s, child ] }
        unless %w[closed open].include?(normalized.fetch("automatic_state")) &&
               [ true, false ].include?(normalized.fetch("manual_blocked")) &&
               [ true, false ].include?(normalized.fetch("probe_owned"))
          raise InvalidMutation, "audit state contains invalid circuit metadata"
        end
        ProviderHealth.nonnegative_integer(normalized.fetch("generation"), "audit state generation")
        ProviderHealth.nonnegative_integer(normalized.fetch("journal_epoch"), "audit state epoch")
        ProviderHealth.deep_freeze(normalized)
      end

      def validate_reference(value)
        return nil if value.nil?

        Hive::Attempts::OutputReference.validate_shape!(value)
        ProviderHealth.deep_freeze(ProviderHealth.deep_copy(value))
      rescue Hive::Attempts::InvalidOutputReference => e
        raise InvalidMutation, e.message
      end
    end
  end
end
