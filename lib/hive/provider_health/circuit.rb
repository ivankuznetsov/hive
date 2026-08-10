require "hive/provider_health"

module Hive
  module ProviderHealth
    class Circuit
      AUTOMATIC_STATES = %w[closed open].freeze

      attr_reader :scope, :automatic_state, :generation, :journal_epoch,
                  :eligible_at, :evidence, :manual_block, :probe, :last_event_id

      def self.closed(scope:, generation: 0, journal_epoch: 0)
        new(
          scope: scope,
          automatic_state: "closed",
          generation: generation,
          journal_epoch: journal_epoch,
          eligible_at: nil,
          evidence: nil,
          manual_block: nil,
          probe: nil,
          last_event_id: nil
        )
      end

      def self.from_h(data)
        scope = ProviderHealth.scope_from_h(data.fetch("scope"))
        new(
          scope: scope,
          automatic_state: data.fetch("automatic_state"),
          generation: data.fetch("generation"),
          journal_epoch: data.fetch("journal_epoch"),
          eligible_at: data["eligible_at"],
          evidence: data["evidence"],
          manual_block: data["manual_block"],
          probe: data["probe"],
          last_event_id: data["last_event_id"]
        )
      end

      def initialize(scope:, automatic_state:, generation:, journal_epoch:, eligible_at:,
                     evidence:, manual_block:, probe:, last_event_id:)
        raise InvalidScope, "circuit requires a provider-health scope" unless scope.is_a?(Scope)
        state = automatic_state.to_s
        raise InvalidMutation, "invalid automatic circuit state" unless AUTOMATIC_STATES.include?(state)

        @scope = scope
        @automatic_state = state.freeze
        @generation = ProviderHealth.nonnegative_integer(generation, "circuit generation")
        @journal_epoch = ProviderHealth.nonnegative_integer(journal_epoch, "journal epoch")
        @eligible_at = eligible_at && ProviderHealth.parse_time(eligible_at, "eligible_at").iso8601(6).freeze
        @evidence = frozen_hash(evidence)
        @manual_block = frozen_hash(manual_block)
        @probe = frozen_hash(probe)
        @last_event_id = last_event_id&.to_s&.freeze
        validate_composition!
        freeze
      end

      def blocked? = !manual_block.nil?
      def probe_owned? = !probe.nil?

      def effective_state(now: Time.now.utc)
        return "manual_block" if blocked?
        return "probe_owned" if probe_owned?
        return "closed" if automatic_state == "closed"
        return "half_open" if eligible_at && ProviderHealth.parse_time(now, "now") >= Time.iso8601(eligible_at)

        "open"
      end

      def eligible?(now: Time.now.utc)
        !blocked? && !probe_owned? && %w[closed half_open].include?(effective_state(now: now))
      end

      def half_open?(now: Time.now.utc) = effective_state(now: now) == "half_open"

      def with(**changes)
        self.class.new(
          scope: changes.fetch(:scope, scope),
          automatic_state: changes.fetch(:automatic_state, automatic_state),
          generation: changes.fetch(:generation, generation),
          journal_epoch: changes.fetch(:journal_epoch, journal_epoch),
          eligible_at: changes.fetch(:eligible_at, eligible_at),
          evidence: changes.fetch(:evidence, evidence),
          manual_block: changes.fetch(:manual_block, manual_block),
          probe: changes.fetch(:probe, probe),
          last_event_id: changes.fetch(:last_event_id, last_event_id)
        )
      end

      def to_h
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "scope" => scope.to_h,
          "journal_epoch" => journal_epoch,
          "generation" => generation,
          "automatic_state" => automatic_state,
          "eligible_at" => eligible_at,
          "evidence" => evidence,
          "manual_block" => manual_block,
          "probe" => probe,
          "last_event_id" => last_event_id
        }.freeze
      end

      private

      def frozen_hash(value)
        return nil if value.nil?
        raise InvalidMutation, "circuit metadata must be an object" unless value.is_a?(Hash)

        ProviderHealth.deep_freeze(ProviderHealth.deep_copy(value))
      end

      def validate_composition!
        if automatic_state == "closed" && (!eligible_at.nil? || !evidence.nil?)
          raise InvalidMutation, "closed circuit cannot retain automatic evidence or eligible_at"
        end
        if automatic_state == "open" && evidence.nil?
          raise InvalidMutation, "open circuit requires sanitized evidence"
        end
      end
    end
  end
end
