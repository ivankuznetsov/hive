require "securerandom"
require "time"
require "hive/provider_health"
require "hive/provider_health/audit"
require "hive/provider_health/circuit"
require "hive/provider_health/evidence"
require "hive/provider_routing/policy_repository"
require "hive/runtime_control_plane"

module Hive
  module ProviderHealth
    # SQL authority for provider eligibility, probe ownership, and audit.
    # Callers may inspect outside admission; AdmissionTransition alone mutates
    # probe ownership while creating an attempt.
    class Repository
      DEFAULT_COOLDOWN_SECONDS = 300
      MAX_AUDIT_EVENTS = 4096

      attr_reader :database

      def initialize(database:, clock: -> { Time.now.utc })
        @database = database
        @clock = clock
      end

      def inspect_scope(scope, now: current_time)
        inspect_scopes([ scope ], now: now).first
      end

      def inspect_scopes(scopes, now: current_time)
        Array(scopes).map do |scope|
          require_scope!(scope)
          database.read { |db| inspection_for(db, scope) }
        end.freeze
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise Unavailable, "provider health is unavailable: #{error.message}"
      end

      def evaluate_route(account_id:, model_id:, now: current_time)
        evaluate_routes(routes: [ { account_id: account_id, model_id: model_id } ], now: now).first
      end

      def evaluate_routes(routes:, now: current_time)
        database.read do |db|
          Array(routes).map do |route|
            scopes = route_scopes(route)
            inspections = scopes.map { |scope| inspection_for(db, scope) }
            route_evaluation(inspections, now: now)
          end.freeze
        end
      rescue InvalidScope, InvalidMutation
        raise
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise Unavailable, "provider health is unavailable: #{error.message}"
      end

      def apply_evidence(evidence:, attempt:, terminal_receipt:, expected_generation:)
        unless evidence.is_a?(Evidence) && attempt.is_a?(AttemptBinding)
          raise InvalidMutation, "health evidence requires typed evidence and attempt bindings"
        end
        receipt = normalize_receipt(terminal_receipt, attempt.attempt_id)
        key = evidence.idempotency_key(receipt_identity: receipt)
        cooldown = cooldown_for(evidence, attempt)
        database.transaction do |db|
          circuit = circuit_for(db, evidence.scope)
          duplicate = duplicate_result(db, circuit, key)
          next duplicate if duplicate
          rejection = evidence_rejection(
            db, evidence, attempt,
            expected_generation: expected_generation, circuit: circuit
          )
          next persist_rejection(db, circuit, key, rejection) if rejection

          unless cooldown.between?(0, MAX_RESET_HINT_SECONDS)
            raise InvalidMutation, "provider-health cooldown is outside the allowed bound"
          end
          eligible_at = current_time + (evidence.reset_hint_seconds || cooldown)
          updated = circuit.with(
            automatic_state: "open", generation: circuit.generation + 1,
            eligible_at: eligible_at, evidence: evidence.to_h, probe: nil
          )
          persist_mutation(db, circuit, updated, key: key, kind: "evidence_opened")
        end
      end

      def complete_probe(attempt:, terminal_receipt:, outcome:)
        unless attempt.is_a?(AttemptBinding) && %w[success failure lost cancelled].include?(outcome.to_s)
          raise InvalidMutation, "probe completion requires a typed attempt and outcome"
        end
        receipt = normalize_receipt(terminal_receipt, attempt.attempt_id)
        database.transaction do |db|
          attempt.probe_bindings.map do |binding|
            circuit = circuit_for(db, binding.scope)
            key = ProviderHealth.digest(
              "probe_binding" => binding.to_h,
              "terminal_receipt" => receipt,
              "outcome" => outcome.to_s
            )
            duplicate = duplicate_result(db, circuit, key)
            next duplicate if duplicate
            unless current_attempt_in?(db, attempt) && circuit.probe == binding.to_h
              next persist_rejection(db, circuit, key, "fenced_attempt")
            end

            updated = if outcome.to_s == "success"
              circuit.with(
                automatic_state: "closed", generation: circuit.generation + 1,
                eligible_at: nil, evidence: nil, probe: nil
              )
            else
              circuit.with(
                generation: circuit.generation + 1,
                eligible_at: current_time + DEFAULT_COOLDOWN_SECONDS, probe: nil
              )
            end
            persist_mutation(
              db, circuit, updated, key: key,
              kind: outcome.to_s == "success" ? "probe_closed" : "probe_reopened"
            )
          end.freeze
        end
      end

      def block(scope:, expected_generation:, actor:, reason:)
        operator_mutation(scope, expected_generation, actor, reason, "block")
      end

      def unblock(scope:, expected_generation:, actor:, reason:)
        operator_mutation(scope, expected_generation, actor, reason, "unblock")
      end

      def reset(scope:, expected_generation:, actor:, reason:)
        operator_mutation(scope, expected_generation, actor, reason, "reset")
      end

      # AdmissionTransition calls this inside its own immediate transaction.
      def claim_probe_bindings_in(db, requirements:, attempt_id:, task_generation:,
                                  ownership_fence:, now: current_time)
        Array(requirements).map do |requirement|
          unless requirement.is_a?(ProbeRequirement)
            raise InvalidMutation, "provider probe requirement is invalid"
          end
          circuit = circuit_for(db, requirement.scope)
          unless circuit.generation == requirement.observed_generation &&
                 circuit.journal_epoch == requirement.journal_epoch &&
                 circuit.half_open?(now: now) && !circuit.blocked? && !circuit.probe_owned?
            raise StaleGeneration, "provider-health probe requirement changed"
          end
          binding = ProbeBinding.new(
            scope: requirement.scope,
            journal_epoch: circuit.journal_epoch,
            observed_generation: circuit.generation,
            claim_generation: circuit.generation + 1,
            attempt_id: attempt_id,
            task_generation: task_generation,
            ownership_fence: ownership_fence
          )
          updated = circuit.with(
            generation: circuit.generation + 1, probe: binding.to_h
          )
          persist_mutation(
            db, circuit, updated,
            key: ProviderHealth.digest("probe" => binding.to_h), kind: "probe_claimed"
          )
          binding
        end.freeze
      end

      def validate_route_in(db, decision, now: current_time)
        decision.circuit_generations.each do |entry|
          scope = ProviderHealth.scope_from_h(entry.fetch("scope"))
          circuit = circuit_for(db, scope)
          unless circuit.generation == entry.fetch("observed_generation") &&
                 circuit.journal_epoch == entry.fetch("journal_epoch")
            raise StaleGeneration, "provider-health route generation changed"
          end
          unless circuit.eligible?(now: now)
            raise StaleGeneration, "provider-health route is no longer eligible"
          end
        end
        true
      end

      private

      def current_time = @clock.call.utc

      def inspection_for(db, scope)
        circuit = circuit_for(db, scope)
        Inspection.new(status: "available", scope: scope, circuit: circuit,
                       generation: circuit.generation, journal_epoch: circuit.journal_epoch)
      end

      def require_scope!(scope)
        raise InvalidScope, "provider-health scope is invalid" unless scope.is_a?(Scope)
      end

      def route_scopes(route)
        account = route.fetch(:account_id) { route.fetch("account_id") }
        model = route.fetch(:model_id) { route.fetch("model_id") }
        [
          Scope.provider_account(account_id: account),
          Scope.model(account_id: account, model_id: model)
        ]
      rescue KeyError
        raise InvalidScope, "provider route scope is incomplete"
      end

      def route_evaluation(inspections, now:)
        blockers = []
        requirements = []
        inspections.each do |inspection|
          circuit = inspection.circuit
          reasons = if circuit.blocked?
            [ "manual_block" ]
          elsif circuit.probe_owned?
            [ "half_open_probe_owned" ]
          elsif circuit.automatic_state == "open" && !circuit.half_open?(now: now)
            %w[circuit_open circuit_cooldown]
          else
            []
          end
          if reasons.empty?
            if circuit.half_open?(now: now)
              requirements << ProbeRequirement.new(
                scope: circuit.scope, journal_epoch: circuit.journal_epoch,
                observed_generation: circuit.generation
              )
            end
          else
            observation = ProviderHealth.circuit_observation(inspection, now: now)
            blockers.concat(reasons.map { |reason| observation.merge("reason" => reason) })
          end
        end
        RouteEvaluation.new(
          status: blockers.empty? ? "eligible" : "excluded",
          inspections: inspections, blockers: blockers,
          probe_requirements: blockers.empty? ? requirements : []
        )
      end

      def circuit_for(db, scope)
        row = db[:provider_circuits].where(circuit_id: scope.key).first
        return Circuit.closed(scope: scope) unless row

        Circuit.new(
          scope: scope, automatic_state: row.fetch(:automatic_state),
          generation: row.fetch(:generation), journal_epoch: row.fetch(:journal_epoch),
          eligible_at: row[:eligible_at], evidence: decode(row[:evidence_json]),
          manual_block: decode(row[:manual_block_json]), probe: decode(row[:probe_json]),
          last_event_id: row[:last_event_id]
        )
      rescue KeyError, RuntimeControlPlane::CodecError, InvalidMutation => error
        raise Unavailable, "provider circuit row is invalid: #{error.message}"
      end

      def persist_circuit(db, circuit)
        values = {
          circuit_id: circuit.scope.key, scope_kind: circuit.scope.kind,
          provider_account_id: circuit.scope.account_id, model: circuit.scope.model_id.to_s,
          automatic_state: circuit.automatic_state, manual_block: circuit.blocked? ? 1 : 0,
          manual_block_json: encode(circuit.manual_block), generation: circuit.generation,
          journal_epoch: circuit.journal_epoch,
          probe_attempt_id: circuit.probe&.fetch("attempt_id", nil),
          probe_json: encode(circuit.probe), eligible_at: circuit.eligible_at,
          evidence_json: encode(circuit.evidence), last_event_id: circuit.last_event_id,
          updated_at: current_time.iso8601(6)
        }
        db[:provider_circuits].insert_conflict(
          target: :circuit_id, update: values.except(:circuit_id)
        ).insert(values)
      end

      def persist_mutation(db, previous, current, key:, kind:, audit: nil)
        duplicate = duplicate_result(db, previous, key)
        return duplicate if duplicate

        event_id = if current.last_event_id != previous.last_event_id
          current.last_event_id
        else
          SecureRandom.uuid
        end
        current = current.with(last_event_id: event_id)
        persist_circuit(db, current)
        payload = { "previous" => previous.to_h, "current" => current.to_h, "audit" => audit&.to_h }
        append_audit(db, current, event_id: event_id, key: key, kind: kind,
                     status: "accepted", payload: payload)
        prune_audit(db, previous.scope.key)
        MutationResult.new(
          status: "accepted", reason: kind, previous: previous, current: current,
          generation: current.generation, event_id: event_id, audit_receipt: audit
        )
      end

      def persist_rejection(db, circuit, key, reason)
        event_id = SecureRandom.uuid
        persist_circuit(db, circuit) unless db[:provider_circuits].where(circuit_id: circuit.scope.key).any?
        append_audit(db, circuit, event_id: event_id, key: key, kind: "evidence_rejected",
                     status: "rejected", reason: reason, payload: { "reason" => reason })
        MutationResult.new(
          status: "rejected", reason: reason, previous: circuit, current: circuit,
          generation: circuit.generation, event_id: event_id, audit_receipt: nil
        )
      end

      def duplicate_result(db, circuit, key)
        row = db[:provider_audit].where(circuit_id: circuit.scope.key, idempotency_key: key).first
        return unless row

        MutationResult.new(
          status: "duplicate", reason: "duplicate_evidence",
          previous: circuit, current: circuit, generation: circuit.generation,
          event_id: row.fetch(:event_id), audit_receipt: nil
        )
      end

      def append_audit(db, circuit, event_id:, key:, kind:, status:, payload:, reason: nil)
        now = current_time
        db[:provider_audit].insert(
          event_id: event_id, circuit_id: circuit.scope.key, generation: circuit.generation,
          sequence: db[:provider_audit].where(circuit_id: circuit.scope.key).max(:sequence).to_i + 1,
          event_type: kind, idempotency_key: key, status: status, reason: reason,
          payload_json: encode(payload), occurred_at: now.iso8601(6),
          retain_until: (now + 30 * 24 * 60 * 60).iso8601(6)
        )
      end

      def operator_mutation(scope, expected_generation, actor, reason, action)
        require_scope!(scope)
        actor = Audit.validate_actor(actor)
        reason = Audit.validate_reason(reason)
        database.transaction do |db|
          circuit = circuit_for(db, scope)
          unless circuit.generation == Integer(expected_generation)
            raise StaleGeneration, "provider-health generation changed; inspect again"
          end
          now = current_time
          manual = action == "block" ? {
            "actor" => actor, "reason" => reason, "blocked_at" => now.iso8601(6)
          } : (action == "reset" ? circuit.manual_block : nil)
          updated = case action
          when "block", "unblock"
            circuit.with(generation: circuit.generation + 1, manual_block: manual, probe: nil)
          when "reset"
            circuit.with(
              generation: circuit.generation + 1, automatic_state: "closed",
              eligible_at: nil, evidence: nil, probe: nil
            )
          end
          event_id = SecureRandom.uuid
          audit = Audit::Receipt.new(
            actor: actor, reason: reason, target: scope, action: action,
            occurred_at: now, previous_state: audit_state(circuit),
            new_state: audit_state(updated), generation: updated.generation,
            event_id: event_id, artifact_reference: nil
          )
          updated = updated.with(last_event_id: event_id)
          persist_mutation(
            db, circuit, updated,
            key: ProviderHealth.digest(
              "operator" => actor, "action" => action, "scope" => scope.to_h,
              "expected_generation" => circuit.generation, "reason" => reason
            ),
            kind: { "block" => "manual_blocked", "unblock" => "manual_unblocked", "reset" => "reset" }.fetch(action),
            audit: audit
          )
        end
      rescue ArgumentError, TypeError
        raise StaleGeneration, "provider-health expected generation is invalid"
      end

      def audit_state(circuit)
        {
          "automatic_state" => circuit.automatic_state,
          "manual_blocked" => circuit.blocked?, "probe_owned" => circuit.probe_owned?,
          "generation" => circuit.generation, "journal_epoch" => circuit.journal_epoch
        }
      end

      def evidence_rejection(db, evidence, attempt, expected_generation:, circuit:)
        return "stale_generation" unless circuit.generation == Integer(expected_generation)
        return "fenced_attempt" unless current_attempt_in?(db, attempt)
        return "fenced_attempt" unless evidence.attempt_id == attempt.attempt_id
        nil
      rescue ArgumentError, TypeError
        "stale_generation"
      end

      def current_attempt_in?(db, attempt)
        db[:attempts].where(
          attempt_id: attempt.attempt_id,
          task_generation: attempt.task_generation,
          ownership_generation: attempt.ownership_fence,
          state: %w[terminal lost]
        ).any?
      end

      def cooldown_for(evidence, attempt)
        row = database.read do |db|
          db[:attempts].where(
            attempt_id: attempt.attempt_id,
            task_generation: attempt.task_generation,
            ownership_generation: attempt.ownership_fence
          ).select(:subject_json).first
        end
        return DEFAULT_COOLDOWN_SECONDS unless row

        subject = decode(row.fetch(:subject_json))
        policy = ProviderRouting::PolicyRepository.new(store: self).fetch_snapshot(
          ownership_generation: attempt.ownership_fence,
          subject: subject
        )
        value = policy&.account_policy&.dig(
          evidence.route.account_id, "cooldown_sec", evidence.failure_class
        )
        Integer(value || DEFAULT_COOLDOWN_SECONDS)
      rescue ProviderRouting::PolicyRepository::Error, KeyError,
             ArgumentError, TypeError => error
        raise Unavailable, "provider cooldown policy is unavailable: #{error.message}"
      end

      def normalize_receipt(receipt, attempt_id)
        fields = %w[attempt_id receipt_version terminal_lease_version]
        unless receipt.is_a?(Hash) && receipt.keys.sort == fields.sort &&
               receipt.fetch("attempt_id") == attempt_id
          raise InvalidMutation, "terminal receipt identity is invalid"
        end
        ProviderHealth.deep_freeze(ProviderHealth.deep_copy(receipt))
      end

      def prune_audit(db, circuit_id)
        ids = db[:provider_audit].where(circuit_id: circuit_id)
          .reverse_order(:sequence).offset(MAX_AUDIT_EVENTS).select_map(:event_id)
        db[:provider_audit].where(event_id: ids).delete unless ids.empty?
      end

      def encode(value) = value.nil? ? nil : RuntimeControlPlane::Codec.dump_json(value)
      def decode(value) = value.nil? ? nil : RuntimeControlPlane::Codec.load_json(value)
    end
  end
end
