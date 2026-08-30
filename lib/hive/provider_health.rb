require "time"
require "hive"
require "hive/canonical_json"

module Hive
  # Host-global provider-account and exact-model health. The domain owns only
  # conservative eligibility state; retry timing, charges, successors, and
  # dispatch remain outside this namespace.
  module ProviderHealth
    class Error < Hive::Error; end
    class InvalidScope < Error; end
    class InvalidEvidence < Error; end
    class InvalidMutation < Error; end
    class StaleGeneration < Error; end
    class Unavailable < Error; end

    SCHEMA = "hive-provider-health".freeze
    EVENT_SCHEMA = "hive-provider-health-event".freeze
    SCHEMA_VERSION = 1

    PROVIDER_FAILURE_CLASSES = %w[
      authentication
      billing_configuration
      exhausted_credits
      account_quota
      provider_rate_limit
      provider_outage
    ].freeze
    MODEL_FAILURE_CLASSES = %w[
      unavailable
      disabled
      deprecated
      model_quota
      model_rate
      model_capacity
    ].freeze
    FAILURE_CLASSES = (PROVIDER_FAILURE_CLASSES + MODEL_FAILURE_CLASSES).freeze
    TRUSTED_PROVENANCE = %w[
      claude_stream_json_transport
      codex_jsonl_transport
      grok_streaming_json_transport
      pi_json_transport
      provider_diagnostic
    ].freeze

    MUTATING_EVENT_KINDS = %w[
      evidence_opened
      probe_claimed
      probe_closed
      probe_reopened
      probe_reconciled
      manual_blocked
      manual_unblocked
      reset
    ].freeze
    NONMUTATING_EVENT_KINDS = %w[evidence_rejected snapshot].freeze
    EVENT_KINDS = (MUTATING_EVENT_KINDS + NONMUTATING_EVENT_KINDS).freeze

    MAX_ID_BYTES = 128
    MAX_REASON_BYTES = 240
    MAX_ACTOR_BYTES = 128
    MAX_RESET_HINT_SECONDS = 7 * 24 * 60 * 60
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    CIRCUIT_OBSERVATION_KEYS = %w[
      eligible_at generation journal_epoch manual_block probe_owner scope state status
    ].freeze

    Scope = Data.define(:kind, :account_id, :model_id) do
      def self.provider_account(account_id:)
        new(kind: "provider_account", account_id: account_id, model_id: nil)
      end

      def self.model(account_id:, model_id:)
        new(kind: "model", account_id: account_id, model_id: model_id)
      end

      def initialize(kind:, account_id:, model_id: nil)
        normalized_kind = kind.to_s
        account = ProviderHealth.identifier(account_id, "provider account")
        model = model_id.nil? ? nil : ProviderHealth.identifier(model_id, "model")
        unless %w[provider_account model].include?(normalized_kind)
          raise InvalidScope, "provider-health scope kind must be provider_account or model"
        end
        if normalized_kind == "provider_account" && !model.nil?
          raise InvalidScope, "provider-account scope cannot include a model"
        end
        if normalized_kind == "model" && model.nil?
          raise InvalidScope, "model scope requires an exact model"
        end

        super(kind: normalized_kind.freeze, account_id: account, model_id: model)
        freeze
      end

      def provider_account? = kind == "provider_account"
      def model? = kind == "model"

      def to_h
        {
          "kind" => kind,
          "provider_account_id" => account_id,
          "model" => model_id
        }.freeze
      end

      def key
        ProviderHealth.digest(to_h).freeze
      end
    end

    RouteIdentity = Data.define(
      :route_id, :account_id, :adapter, :launch_binding_id, :model_id
    ) do
      def self.from_h(data)
        new(
          route_id: data.fetch("route_id"), account_id: data.fetch("provider_account_id"),
          adapter: data.fetch("adapter"), launch_binding_id: data.fetch("launch_binding_id"),
          model_id: data.fetch("model")
        )
      end

      def initialize(route_id:, account_id:, adapter:, launch_binding_id:, model_id:)
        super(
          route_id: ProviderHealth.identifier(route_id, "route"),
          account_id: ProviderHealth.identifier(account_id, "provider account"),
          adapter: ProviderHealth.identifier(adapter, "adapter"),
          launch_binding_id: ProviderHealth.identifier(launch_binding_id, "launch binding"),
          model_id: ProviderHealth.identifier(model_id, "model")
        )
        freeze
      end

      def to_h
        {
          "route_id" => route_id,
          "provider_account_id" => account_id,
          "adapter" => adapter,
          "launch_binding_id" => launch_binding_id,
          "model" => model_id
        }.freeze
      end
    end

    ProbeBinding = Data.define(
      :scope, :journal_epoch, :observed_generation, :claim_generation,
      :attempt_id, :task_generation, :ownership_fence
    ) do
      def self.from_h(data)
        new(
          scope: ProviderHealth.scope_from_h(data.fetch("scope")),
          **data.slice(
            "journal_epoch", "observed_generation", "claim_generation", "attempt_id",
            "task_generation", "ownership_fence"
          ).transform_keys(&:to_sym)
        )
      end

      def initialize(scope:, journal_epoch:, observed_generation:, claim_generation:,
                     attempt_id:, task_generation:, ownership_fence:)
        unless scope.is_a?(Scope)
          raise InvalidMutation, "probe binding requires a provider-health scope"
        end
        epoch = ProviderHealth.nonnegative_integer(journal_epoch, "journal epoch")
        observed = ProviderHealth.nonnegative_integer(observed_generation, "observed generation")
        claim = ProviderHealth.nonnegative_integer(claim_generation, "claim generation")
        unless claim == observed + 1
          raise InvalidMutation, "probe claim generation must follow the observed generation"
        end
        super(
          scope: scope,
          journal_epoch: epoch,
          observed_generation: observed,
          claim_generation: claim,
          attempt_id: ProviderHealth.identifier(attempt_id, "attempt"),
          task_generation: ProviderHealth.identifier(task_generation, "task generation"),
          ownership_fence: ProviderHealth.identifier(ownership_fence, "ownership fence")
        )
        freeze
      end

      def to_h
        {
          "scope" => scope.to_h,
          "journal_epoch" => journal_epoch,
          "observed_generation" => observed_generation,
          "claim_generation" => claim_generation,
          "attempt_id" => attempt_id,
          "task_generation" => task_generation,
          "ownership_fence" => ownership_fence
        }.freeze
      end
    end

    ProbeRequirement = Data.define(:scope, :journal_epoch, :observed_generation) do
      def initialize(scope:, journal_epoch:, observed_generation:)
        unless scope.is_a?(Scope)
          raise InvalidMutation, "probe requirement requires a provider-health scope"
        end
        super(
          scope: scope,
          journal_epoch: ProviderHealth.nonnegative_integer(journal_epoch, "journal epoch"),
          observed_generation: ProviderHealth.nonnegative_integer(
            observed_generation, "observed generation"
          )
        )
        freeze
      end

      def to_h
        {
          "scope" => scope.to_h,
          "journal_epoch" => journal_epoch,
          "observed_generation" => observed_generation
        }.freeze
      end
    end

    AttemptBinding = Data.define(
      :attempt_id, :task_generation, :ownership_fence, :route, :probe_bindings
    ) do
      def initialize(attempt_id:, task_generation:, ownership_fence:, route:, probe_bindings: [])
        unless route.is_a?(RouteIdentity)
          raise InvalidMutation, "attempt binding requires a provider route identity"
        end
        bindings = Array(probe_bindings)
        unless bindings.all? { |binding| binding.is_a?(ProbeBinding) }
          raise InvalidMutation, "attempt probe bindings must be provider-health probe bindings"
        end
        super(
          attempt_id: ProviderHealth.identifier(attempt_id, "attempt"),
          task_generation: ProviderHealth.identifier(task_generation, "task generation"),
          ownership_fence: ProviderHealth.identifier(ownership_fence, "ownership fence"),
          route: route,
          probe_bindings: bindings.dup.freeze
        )
        freeze
      end

      def to_h
        {
          "attempt_id" => attempt_id,
          "task_generation" => task_generation,
          "ownership_fence" => ownership_fence,
          "route" => route.to_h,
          "probe_bindings" => probe_bindings.map(&:to_h)
        }.freeze
      end
    end

    Inspection = Data.define(
      :status, :scope, :circuit, :generation, :journal_epoch,
      :unavailable_reason, :corruption_token, :artifact_reference
    ) do
      def initialize(status:, scope:, circuit:, generation:, journal_epoch:,
                     unavailable_reason: nil, corruption_token: nil, artifact_reference: nil)
        super(
          status: status.to_s.freeze,
          scope: scope,
          circuit: circuit,
          generation: Integer(generation),
          journal_epoch: Integer(journal_epoch),
          unavailable_reason: unavailable_reason&.to_s&.freeze,
          corruption_token: corruption_token,
          artifact_reference: ProviderHealth.deep_freeze(
            ProviderHealth.deep_copy(artifact_reference)
          )
        )
        freeze
      end

      def available? = status == "available"
      def unavailable? = !available?
    end

    RouteEvaluation = Data.define(:status, :inspections, :blockers, :probe_requirements) do
      def initialize(status:, inspections:, blockers:, probe_requirements:)
        requirements = Array(probe_requirements)
        unless requirements.all? { |value| value.is_a?(ProbeRequirement) }
          raise InvalidMutation, "route evaluation probe requirements are invalid"
        end
        super(
          status: status.to_s.freeze,
          inspections: Array(inspections).dup.freeze,
          blockers: ProviderHealth.deep_freeze(ProviderHealth.deep_copy(blockers)),
          probe_requirements: requirements.dup.freeze
        )
        freeze
      end

      def eligible? = status == "eligible"
    end

    MutationResult = Data.define(
      :status, :reason, :previous, :current, :generation, :event_id, :audit_receipt
    ) do
      def initialize(status:, reason:, previous:, current:, generation:, event_id: nil,
                     audit_receipt: nil)
        super(
          status: status.to_s.freeze,
          reason: reason.to_s.freeze,
          previous: previous,
          current: current,
          generation: Integer(generation),
          event_id: event_id&.to_s&.freeze,
          audit_receipt: audit_receipt
        )
        freeze
      end

      def accepted? = status == "accepted"
      def duplicate? = status == "duplicate"
    end

    autoload :Audit, File.expand_path("provider_health/audit.rb", __dir__)
    autoload :AttemptObserver, File.expand_path("provider_health/attempt_observer.rb", __dir__)
    autoload :Circuit, File.expand_path("provider_health/circuit.rb", __dir__)
    autoload :Event, File.expand_path("provider_health/event.rb", __dir__)
    autoload :Evidence, File.expand_path("provider_health/evidence.rb", __dir__)
    autoload :Repository, File.expand_path("provider_health/repository.rb", __dir__)

    module_function

    def identifier(value, label)
      string = value.to_s
      unless value.is_a?(String) && !string.empty? && string.bytesize <= MAX_ID_BYTES &&
             string.valid_encoding? && !string.match?(/[\u0000-\u001f\u007f]/)
        raise InvalidMutation, "#{label} identity is invalid"
      end
      string.dup.freeze
    end

    def nonnegative_integer(value, label)
      number = Integer(value)
      raise InvalidMutation, "#{label} must be non-negative" if number.negative?

      number
    rescue ArgumentError, TypeError
      raise InvalidMutation, "#{label} must be a non-negative integer"
    end

    def scope_from_h(data)
      unless data.is_a?(Hash) && data.keys.sort == %w[kind model provider_account_id]
        raise InvalidScope, "provider-health scope object is invalid"
      end
      case data.fetch("kind")
      when "provider_account"
        raise InvalidScope, "provider-account scope model must be null" unless data["model"].nil?

        Scope.provider_account(account_id: data.fetch("provider_account_id"))
      when "model"
        Scope.model(
          account_id: data.fetch("provider_account_id"),
          model_id: data.fetch("model")
        )
      else
        raise InvalidScope, "provider-health scope kind is invalid"
      end
    rescue KeyError
      raise InvalidScope, "provider-health scope object is incomplete"
    end

    def canonical_json(value)
      Hive::CanonicalJSON.generate(value)
    end

    def digest(value)
      Hive::CanonicalJSON.digest(value)
    end

    def circuit_observation(inspection, now: Time.now.utc)
      unless inspection.is_a?(Inspection)
        raise InvalidMutation, "circuit observation requires a provider-health inspection"
      end
      circuit = inspection.circuit
      {
        "scope" => inspection.scope.to_h,
        "status" => inspection.status,
        "generation" => inspection.generation,
        "journal_epoch" => inspection.journal_epoch,
        "state" => circuit&.effective_state(now: now) || "health_state_unavailable",
        "manual_block" => circuit&.blocked?,
        "eligible_at" => circuit&.eligible_at,
        "probe_owner" => circuit&.probe
      }.freeze
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      when String
        value.freeze
      end
      value&.freeze
    end

    def deep_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [ key.to_s.dup, deep_copy(child) ] }
      when Array
        value.map { |child| deep_copy(child) }
      when String
        value.dup
      else
        value
      end
    end

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.utc
    rescue ArgumentError
      raise InvalidMutation, "#{label} must be an RFC3339 timestamp"
    end

    def open(database: nil, **options)
      require "hive/runtime_control_plane"
      require "hive/provider_health/repository"

      database ||= RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path
      ).open!
      Repository.new(database: database, **options)
    end
  end
end
