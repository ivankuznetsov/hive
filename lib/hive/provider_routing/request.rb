require "securerandom"
require "hive/provider_routing"

module Hive
  module ProviderRouting
    class Request
      Exclusion = Data.define(:provider, :model, :checkpoint, :reason)

      attr_reader :configuration, :checkpoint, :exclusions, :provenance,
                  :attempt_id, :agent_config, :profile_overrides

      def initialize(configuration:, checkpoint:, exclusions: [], provenance: {},
                     attempt_id: SecureRandom.uuid, agent_config: nil)
        @configuration = configuration
        @checkpoint = checkpoint.to_s
        @exclusions = exclusions.map { |entry| normalize_exclusion(entry) }.freeze
        @provenance = provenance.to_h.freeze
        @attempt_id = attempt_id.to_s
        @agent_config = agent_config
        @profile_overrides = {}
        freeze
      end

      def self.with_profiles(configuration:, checkpoint:, exclusions: [], provenance: {},
                             attempt_id: SecureRandom.uuid, agent_config: nil, profiles: {})
        request = allocate
        request.send(
          :initialize_with_profiles,
          configuration: configuration,
          checkpoint: checkpoint,
          exclusions: exclusions,
          provenance: provenance,
          attempt_id: attempt_id,
          agent_config: agent_config,
          profiles: profiles
        )
        request
      end

      def profile_for(agent)
        profile_overrides[agent.to_s]
      end

      def excluded?(candidate)
        exclusions.any? do |entry|
          entry.checkpoint == checkpoint && entry.provider == candidate.provider &&
            entry.model == candidate.model
        end
      end

      def with_exclusion(provider:, model:, reason: "context_length")
        self.class.with_profiles(
          configuration: configuration,
          checkpoint: checkpoint,
          exclusions: exclusions + [
            Exclusion.new(provider: provider.to_s, model: model&.to_s,
                          checkpoint: checkpoint, reason: reason.to_s)
          ],
          provenance: provenance,
          attempt_id: SecureRandom.uuid,
          agent_config: agent_config,
          profiles: profile_overrides
        )
      end

      private

      def initialize_with_profiles(configuration:, checkpoint:, exclusions:, provenance:,
                                   attempt_id:, agent_config:, profiles:)
        @configuration = configuration
        @checkpoint = checkpoint.to_s
        @exclusions = exclusions.map { |entry| normalize_exclusion(entry) }.freeze
        @provenance = provenance.to_h.freeze
        @attempt_id = attempt_id.to_s
        @agent_config = agent_config
        @profile_overrides = profiles.transform_keys(&:to_s).freeze
        freeze
      end

      def normalize_exclusion(entry)
        return entry if entry.is_a?(Exclusion)

        value = entry.transform_keys(&:to_sym)
        Exclusion.new(
          provider: value.fetch(:provider).to_s,
          model: value[:model]&.to_s,
          checkpoint: value.fetch(:checkpoint, checkpoint).to_s,
          reason: value.fetch(:reason, "context_length").to_s
        )
      end
    end
  end
end
