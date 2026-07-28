require "hive/config"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/patrols"

module Hive
  module Patrol
    # Ordinary patrol's sole authorization boundary for externally observable
    # effects. Recovery remains in the caller-provided fingerprint mapping;
    # observational evidence is deliberately write-only from this boundary.
    class EffectGateway
      Result = Data.define(:status, :outcome, :receipt)

      class Denied < StandardError
        attr_reader :reason, :receipt

        def initialize(reason, receipt)
          @reason = reason.to_s.freeze
          @receipt = receipt
          super("patrol effect denied: #{@reason}")
        end
      end

      class ReconciliationRequired < StandardError
        attr_reader :reason, :receipt

        def initialize(reason, receipt)
          @reason = reason.to_s.freeze
          @receipt = receipt
          super("patrol effect requires exact reconciliation: #{@reason}")
        end
      end

      def initialize(project_root:, hive_state_path:, capture:, authority:, evidence_store:,
                     intent_writer:, recovery_reader:, outcome_writer:,
                     migration_lock: nil, ownership_loader: nil, config_loader: nil,
                     capability_checker: nil, clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @hive_state_path = File.expand_path(hive_state_path)
        @capture = validate_capture(capture)
        @authority = authority.to_s
        validate_authority!
        @evidence_store = evidence_store
        @intent_writer = intent_writer
        @recovery_reader = recovery_reader
        @outcome_writer = outcome_writer
        @migration_lock = migration_lock || method(:with_default_migration_lock)
        @ownership_loader = ownership_loader || method(:load_default_ownership)
        @config_loader = config_loader || ->(root) { Hive::Config.load(root) }
        @capability_checker = capability_checker || method(:default_capability_allowed?)
        @clock = clock
      end

      def perform!(sink:, target:, idempotency_key:, capability:, claim_generation: nil,
                   reconcile: nil, &effect)
        raise ArgumentError, "an effect block is required" unless effect

        intent = build_intent(
          sink: sink, target: target, idempotency_key: idempotency_key,
          capability: capability, claim_generation: claim_generation
        )
        disposition = @authority == "shadow" ? :shadow : @intent_writer.call(intent)

        @migration_lock.call do
          ownership = @ownership_loader.call
          config = @config_loader.call(@project_root)
          deny_reason = ownership_denial(ownership) || configuration_denial(config)
          return deny!(intent, deny_reason) if deny_reason
          return shadow_attempt!(intent) if @authority == "shadow"

          unless @capability_checker.call(
            config: config, capability: intent.capability, sink: intent.sink,
            target: intent.target, authority: @authority
          )
            return deny!(intent, "capability_revoked")
          end

          recover_or_apply!(intent, disposition, reconcile, &effect)
        end
      end

      private

      def validate_capture(capture)
        unless capture.is_a?(Hive::Modules::Migration::PatrolCapture) &&
               capture.module_name == "patrol"
          raise Hive::ConfigError, "ordinary patrol effect capture is malformed"
        end

        capture
      end

      def validate_authority!
        allowed = Hive::Modules::Migration::PatrolEvidence::AUTHORITIES
        return if allowed.include?(@authority)

        raise Hive::ConfigError, "ordinary patrol effect authority is malformed"
      end

      def build_intent(sink:, target:, idempotency_key:, capability:, claim_generation:)
        Hive::Modules::Migration::EffectIntent.build(
          module_name: "patrol",
          occurrence_id: @capture.occurrence_id,
          authority: @authority,
          owner_epoch: @capture.owner_epoch,
          sink: sink,
          target: target,
          idempotency_key: idempotency_key,
          capability: capability,
          claim_generation: claim_generation,
          created_at: @capture.recorded_at
        )
      end

      def ownership_denial(snapshot)
        return "migration_state_unavailable" unless snapshot.is_a?(Hash)
        return "stale_owner_epoch" unless snapshot["epoch"] == @capture.owner_epoch
        return "ownership_changed" unless snapshot["owner"] == @capture.owner
        return "admission_closed" unless snapshot["admission"] == true
        return if @authority == "shadow"
        return "authority_not_owner" unless snapshot["owner"] == @authority

        nil
      end

      def configuration_denial(config)
        settings = config.is_a?(Hash) ? config["patrol"] : nil
        return "configuration_unavailable" unless settings.is_a?(Hash)
        return "configuration_disabled" unless settings.fetch("enabled", true) == true

        nil
      end

      def recover_or_apply!(intent, disposition, reconcile)
        if disposition.to_sym == :created && reconcile
          reconciliation = exact_reconciliation!(intent, reconcile)
          case reconciliation.fetch("status")
          when "matched"
            return persist!(
              intent, "reconciled", reconciliation.fetch("outcome", {}),
              result_status: :reconciled
            )
          when "absent"
            persist!(intent, "known_not_sent", reconciliation.fetch("outcome", {}))
          else
            return reconciliation_required!(intent, "remote_identity_ambiguous")
          end
        elsif disposition.to_sym == :duplicate
          state = @recovery_reader.call(intent)
          status = state.is_a?(Hash) ? state["status"].to_s : "unknown"
          outcome = state.is_a?(Hash) && state["outcome"].is_a?(Hash) ? state["outcome"] : {}
          return Result.new(status: status.to_sym, outcome: outcome, receipt: nil) if terminal?(status)

          if %w[intent unknown].include?(status)
            reconciliation = exact_reconciliation!(intent, reconcile)
            case reconciliation.fetch("status")
            when "matched"
              return persist!(
                intent, "reconciled", reconciliation.fetch("outcome", {}),
                result_status: :reconciled
              )
            when "absent"
              persist!(intent, "known_not_sent", reconciliation.fetch("outcome", {}))
            else
              return reconciliation_required!(intent, "remote_identity_ambiguous")
            end
          elsif status != "known_not_sent"
            return reconciliation_required!(intent, "recovery_state_unrecognized")
          end
        elsif disposition.to_sym != :created
          return reconciliation_required!(intent, "intent_persistence_unrecognized")
        end

        apply_effect!(intent) { yield }
      end

      def exact_reconciliation!(intent, reconcile)
        return { "status" => "ambiguous", "outcome" => {} } unless reconcile

        result = reconcile.call(intent)
        unless result.is_a?(Hash) &&
               %w[matched absent ambiguous].include?(result["status"]) &&
               result.fetch("outcome", {}).is_a?(Hash)
          return { "status" => "ambiguous", "outcome" => {} }
        end

        result
      end

      def terminal?(status) = %w[committed reconciled].include?(status)

      def apply_effect!(intent)
        outcome = yield
        unless outcome.is_a?(Hash)
          raise Hive::ConfigError, "ordinary patrol effect outcome must be an object"
        end

        persist!(intent, "committed", outcome, result_status: :committed)
      rescue Denied, ReconciliationRequired
        raise
      rescue StandardError => error
        failure = { "error_class" => error.class.name.to_s }
        begin
          persist!(intent, "unknown", failure)
        rescue StandardError
          # The durable intent still forces exact reconciliation on retry.
        end
        raise
      end

      def deny!(intent, reason)
        receipt =
          if @authority == "shadow"
            receipt(intent, "attempted", {
              "attempted" => true, "reason" => reason.to_s
            })
          else
            persist!(intent, "denied", { "reason" => reason.to_s }).receipt
          end
        raise Denied.new(reason, receipt)
      end

      def shadow_attempt!(intent)
        receipt = receipt(intent, "attempted", {
          "attempted" => true, "reason" => "shadow_mutation_forbidden"
        })
        raise Denied.new("shadow_mutation_forbidden", receipt)
      end

      def reconciliation_required!(intent, reason)
        result = persist!(intent, "unknown", { "reason" => reason.to_s })
        raise ReconciliationRequired.new(reason, result.receipt)
      end

      def persist!(intent, status, outcome, result_status: nil)
        @outcome_writer.call(intent, status: status, outcome: outcome)
        receipt = receipt(intent, status, outcome)
        Result.new(status: result_status || status.to_sym, outcome: outcome, receipt: receipt)
      end

      def receipt(intent, status, outcome)
        value = Hive::Modules::Migration::EffectReceipt.build(
          intent: intent, status: status, outcome: outcome, recorded_at: @clock.call
        )
        @evidence_store.append_receipt(value)
        value
      end

      def with_default_migration_lock(&block)
        Hive::Modules::Migration::Patrols.with_migration_lock(
          @project_root, hive_state_path: @hive_state_path, shared: true, &block
        )
      end

      def load_default_ownership
        Hive::Modules::Migration::Patrols.ownership_snapshot(
          @project_root, "patrol", hive_state_path: @hive_state_path
        )
      end

      def default_capability_allowed?(config:, **)
        config.dig("patrol", "enabled") != false
      end
    end
  end
end
