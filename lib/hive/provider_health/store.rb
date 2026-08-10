require "json"
require "securerandom"
require "time"
require "hive/managed_directory"
require "hive/provider_health"
require "hive/provider_health/audit"
require "hive/provider_health/circuit"
require "hive/provider_health/evidence"
require "hive/provider_health/event"

module Hive
  module ProviderHealth
    class Store
      MAX_JOURNAL_BYTES = 2 * 1024 * 1024
      MAX_JOURNAL_EVENTS = 4096
      MAX_INTENT_BYTES = 64 * 1024
      DEFAULT_COOLDOWN_SECONDS = 300
      TERMINAL_RECEIPT_FIELDS = %w[
        attempt_id receipt_version terminal_lease_version
      ].freeze

      Replay = Data.define(:circuit, :events, :bytes, :existed) do
        def sequence = events.length
      end
      private_constant :Replay

      class JournalCorruption < StandardError
        attr_reader :scope, :bytes, :last_circuit

        def initialize(scope:, bytes:, last_circuit:)
          @scope = scope
          @bytes = bytes
          @last_circuit = last_circuit
          super("provider-health journal is unavailable")
        end
      end
      private_constant :JournalCorruption

      attr_reader :root

      def initialize(root:, clock: -> { Time.now.utc }, attempt_reader: nil,
                     cooldown_resolver: nil, fault_injector: nil)
        @root = File.expand_path(root).freeze
        @clock = clock
        @attempt_reader = attempt_reader
        @cooldown_resolver = cooldown_resolver || ->(_evidence) { DEFAULT_COOLDOWN_SECONDS }
        @fault_injector = fault_injector
        @directory = Hive::ManagedDirectory.new(
          root: @root,
          label: "provider-health store"
        ).prepare!
        %w[scopes/provider-account scopes/model intents quarantine].each do |relative|
          @directory.ensure_directory(relative)
        end
      end

      def inspect_scope(scope, now: current_time)
        require_scope!(scope)
        with_mutation_lock do
          replay = load_replay(scope, recover_torn: true, publish_projection: true)
          Inspection.new(
            status: "available",
            scope: scope,
            circuit: replay.circuit,
            generation: replay.circuit.generation,
            journal_epoch: replay.circuit.journal_epoch
          )
        rescue JournalCorruption => corruption
          unavailable_inspection(corruption)
        end
      rescue Hive::ManagedDirectory::UnsafeError
        Inspection.new(
          status: "unavailable",
          scope: scope,
          circuit: nil,
          generation: 0,
          journal_epoch: 0,
          unavailable_reason: "health_state_unavailable"
        )
      end

      def evaluate_route(account_id:, model_id:, now: current_time)
        scopes = [
          Scope.provider_account(account_id: account_id),
          Scope.model(account_id: account_id, model_id: model_id)
        ]
        with_mutation_lock do
          intents = load_intents
          inspections = scopes.map do |scope|
            begin
              replay = load_replay(scope, recover_torn: true, publish_projection: true)
              Inspection.new(
                status: "available",
                scope: scope,
                circuit: replay.circuit,
                generation: replay.circuit.generation,
                journal_epoch: replay.circuit.journal_epoch
              )
            rescue JournalCorruption => corruption
              unavailable_inspection(corruption)
            end
          end
          blockers = []
          requirements = []
          inspections.each do |inspection|
            unless inspection.available?
              blockers << blocker(inspection.scope, "health_state_unavailable", inspection)
              next
            end
            circuit = inspection.circuit
            if unresolved_intent?(inspection.scope, intents)
              blockers << blocker(inspection.scope, "half_open_probe_owned", inspection)
            elsif circuit.blocked?
              blockers << blocker(inspection.scope, "manual_block", inspection)
            elsif circuit.probe_owned?
              blockers << blocker(inspection.scope, "half_open_probe_owned", inspection)
            elsif circuit.half_open?(now: now)
              requirements << ProbeRequirement.new(
                scope: inspection.scope,
                journal_epoch: inspection.journal_epoch,
                observed_generation: inspection.generation
              )
            elsif circuit.automatic_state == "open"
              blockers << blocker(inspection.scope, "circuit_cooldown", inspection)
            end
          end
          RouteEvaluation.new(
            status: blockers.empty? ? "eligible" : "excluded",
            inspections: inspections,
            blockers: blockers,
            probe_requirements: blockers.empty? ? requirements : []
          )
        end
      rescue JournalCorruption => corruption
        inspection = unavailable_inspection(corruption)
        RouteEvaluation.new(
          status: "excluded",
          inspections: [ inspection ],
          blockers: [ blocker(corruption.scope, "health_state_unavailable", inspection) ],
          probe_requirements: []
        )
      rescue Unavailable, Hive::ManagedDirectory::UnsafeError
        inspections = scopes.map do |scope|
          Inspection.new(
            status: "unavailable",
            scope: scope,
            circuit: nil,
            generation: 0,
            journal_epoch: 0,
            unavailable_reason: "health_state_unavailable"
          )
        end
        RouteEvaluation.new(
          status: "excluded",
          inspections: inspections,
          blockers: inspections.map do |inspection|
            blocker(inspection.scope, "health_state_unavailable", inspection)
          end,
          probe_requirements: []
        )
      end

      def apply_evidence(evidence:, attempt:, terminal_receipt:, expected_generation:)
        unless evidence.is_a?(Evidence) && attempt.is_a?(AttemptBinding)
          raise InvalidMutation, "health evidence requires typed evidence and attempt bindings"
        end
        receipt = normalize_terminal_receipt(terminal_receipt, attempt_id: attempt.attempt_id)
        idempotency_key = evidence.idempotency_key(receipt_identity: receipt)

        with_mutation_lock do
          replay = load_replay(evidence.scope, recover_torn: true, publish_projection: true)
          duplicate = duplicate_result(replay, idempotency_key)
          next duplicate if duplicate

          rejection = evidence_rejection(
            evidence: evidence,
            attempt: attempt,
            expected_generation: expected_generation,
            circuit: replay.circuit
          )
          if rejection
            next append_rejection(
              replay,
              reason: rejection,
              idempotency_key: idempotency_key
            )
          end

          cooldown = Integer(@cooldown_resolver.call(evidence))
          unless cooldown.between?(0, MAX_RESET_HINT_SECONDS)
            raise InvalidMutation, "provider-health cooldown is outside the allowed bound"
          end
          eligible_at = current_time + (evidence.reset_hint_seconds || cooldown)
          append_transition(
            replay,
            kind: "evidence_opened",
            idempotency_key: idempotency_key,
            payload: {
              "evidence" => evidence.to_h,
              "eligible_at" => eligible_at.iso8601(6)
            }
          )
        end
      end

      def complete_probe(attempt:, terminal_receipt:, outcome:)
        unless attempt.is_a?(AttemptBinding)
          raise InvalidMutation, "probe completion requires an attempt binding"
        end
        outcome_value = outcome.to_s
        unless %w[success failure lost cancelled].include?(outcome_value)
          raise InvalidMutation, "probe outcome is invalid"
        end
        receipt = normalize_terminal_receipt(terminal_receipt, attempt_id: attempt.attempt_id)
        receipt_identity = ProviderHealth.digest(receipt)

        with_mutation_lock do
          attempt.probe_bindings.map do |binding|
            replay = load_replay(binding.scope, recover_torn: true, publish_projection: true)
            key = ProviderHealth.digest(
              "probe_binding" => binding.to_h,
              "terminal_receipt" => receipt,
              "outcome" => outcome_value
            )
            duplicate = duplicate_result(replay, key)
            next duplicate if duplicate
            unless valid_current_attempt?(attempt) && matching_probe?(replay.circuit, binding)
              next append_rejection(
                replay,
                reason: "fenced_attempt",
                idempotency_key: key
              )
            end

            if outcome_value == "success"
              append_transition(
                replay,
                kind: "probe_closed",
                idempotency_key: key,
                payload: { "receipt_identity" => receipt_identity }
              )
            else
              append_transition(
                replay,
                kind: "probe_reopened",
                idempotency_key: key,
                payload: {
                  "eligible_at" => (current_time + DEFAULT_COOLDOWN_SECONDS).iso8601(6),
                  "receipt_identity" => receipt_identity
                }
              )
            end
          end.freeze
        end
      end

      # Called while Attempts::Dispatcher already owns admission and task-
      # generation locks. The health lock is therefore the innermost lock.
      # The yielded callback must durably persist the launching attempt.
      def with_probe_intent(intent:, &block)
        raise InvalidMutation, "probe intent must be typed" unless intent.is_a?(ProbeIntent)

        with_mutation_lock do
          perform_probe_intent(intent, &block)
        end
      end

      # Revalidates every enclosing scope and, when needed, claims all probes
      # while the admission owner persists the matching attempt. This is the
      # health-side CAS boundary for both ordinary closed routes and half-open
      # routes; speculative selection alone never reserves eligibility.
      def with_route_admission(evaluation:, intent: nil, &block)
        unless evaluation.is_a?(RouteEvaluation) && evaluation.eligible?
          raise InvalidMutation, "route admission requires an eligible health evaluation"
        end
        if intent && !intent.is_a?(ProbeIntent)
          raise InvalidMutation, "route admission probe intent must be typed"
        end

        with_mutation_lock do
          validate_route_evaluation!(evaluation)
          if intent
            observed = evaluation.probe_requirements.map(&:to_h)
            requested = intent.requirements.map(&:to_h)
            unless observed == requested
              raise StaleGeneration, "provider-health probe requirements changed"
            end
            perform_probe_intent(intent, &block)
          else
            unless evaluation.probe_requirements.empty?
              raise StaleGeneration, "provider-health route now requires a probe"
            end
            block.call([].freeze)
          end
        end
      end

      def reconcile!
        with_mutation_lock do
          load_intents.map do |stored|
            reconcile_intent(stored)
          end.freeze
        end
      end

      def block(scope:, expected_generation:, actor:, reason:)
        operator_mutation(
          scope: scope,
          expected_generation: expected_generation,
          actor: actor,
          reason: reason,
          action: "block"
        )
      end

      def unblock(scope:, expected_generation:, actor:, reason:)
        operator_mutation(
          scope: scope,
          expected_generation: expected_generation,
          actor: actor,
          reason: reason,
          action: "unblock"
        )
      end

      def reset(scope:, expected_generation: nil, corruption_token: nil, actor:, reason:)
        require_scope!(scope)
        actor_value = Audit.validate_actor(actor)
        reason_value = Audit.validate_reason(reason)
        with_mutation_lock do
          begin
            replay = load_replay(scope, recover_torn: true, publish_projection: true)
          rescue JournalCorruption => corruption
            next reset_corruption(
              corruption,
              token: corruption_token,
              actor: actor_value,
              reason: reason_value
            )
          end
          if corruption_token
            raise StaleGeneration, "corruption token does not target unavailable health state"
          end
          enforce_generation!(replay.circuit, expected_generation)
          append_operator_transition(
            replay,
            action: "reset",
            actor: actor_value,
            reason: reason_value
          )
        end
      end

      private

      def validate_route_evaluation!(evaluation)
        intents = load_intents
        requirements = evaluation.probe_requirements.to_h do |requirement|
          [ requirement.scope.key, requirement ]
        end
        evaluation.inspections.each do |inspection|
          raise StaleGeneration, "provider-health observation is unavailable" unless inspection.available?
          if unresolved_intent?(inspection.scope, intents)
            raise StaleGeneration, "provider-health scope has an unresolved probe intent"
          end

          replay = load_replay(inspection.scope, recover_torn: true, publish_projection: true)
          circuit = replay.circuit
          unless circuit.journal_epoch == inspection.journal_epoch &&
                 circuit.generation == inspection.generation &&
                 !circuit.blocked? && !circuit.probe_owned?
            raise StaleGeneration, "provider-health route observation is stale"
          end
          requirement = requirements[inspection.scope.key]
          if circuit.automatic_state == "open"
            unless circuit.half_open?(now: current_time) && requirement &&
                   requirement.journal_epoch == circuit.journal_epoch &&
                   requirement.observed_generation == circuit.generation
              raise StaleGeneration, "provider-health route observation is stale"
            end
          elsif requirement
            raise StaleGeneration, "provider-health route probe requirement is stale"
          end
        end
      end

      def perform_probe_intent(intent)
        raise InvalidMutation, "probe intent already exists" if intent_exists?(intent.intent_id)
        intents = load_intents
        replays = intent.requirements.map do |requirement|
          if unresolved_intent?(requirement.scope, intents)
            raise StaleGeneration, "provider-health scope already has an unresolved probe intent"
          end
          replay = load_replay(requirement.scope, recover_torn: true, publish_projection: true)
          circuit = replay.circuit
          unless circuit.journal_epoch == requirement.journal_epoch &&
                 circuit.generation == requirement.observed_generation &&
                 circuit.half_open?(now: current_time) && !circuit.probe_owned? && !circuit.blocked?
            raise StaleGeneration, "provider-health probe observation is stale"
          end
          replay
        end
        bindings = intent.requirements.map do |requirement|
          ProbeBinding.new(
            scope: requirement.scope,
            journal_epoch: requirement.journal_epoch,
            observed_generation: requirement.observed_generation,
            claim_generation: requirement.observed_generation + 1,
            attempt_id: intent.attempt_id,
            task_generation: intent.task_generation,
            ownership_fence: intent.ownership_fence
          )
        end.freeze
        persist_intent(intent, bindings)
        fault!(:intent_persisted, intent: intent)
        yielded = yield(bindings)
        fault!(:attempt_persisted, intent: intent)
        replays.zip(bindings).each_with_index do |(replay, binding), index|
          append_transition(
            replay,
            kind: "probe_claimed",
            idempotency_key: probe_claim_key(intent.intent_id, binding),
            payload: { "probe" => binding.to_h }
          )
          fault!(:claim_persisted, intent: intent, index: index)
        end
        remove_intent(intent.intent_id)
        yielded
      end

      def with_mutation_lock(&block)
        @directory.with_lock("mutation.lock", &block)
      rescue JournalCorruption
        raise Unavailable, "health_state_unavailable"
      end

      def fault!(phase, context)
        @fault_injector&.call(phase, context)
      end

      def require_scope!(scope)
        raise InvalidScope, "provider-health operation requires a scope" unless scope.is_a?(Scope)
      end

      def current_time
        ProviderHealth.parse_time(@clock.call, "provider-health clock")
      end

      def scope_kind_directory(scope)
        scope.provider_account? ? "provider-account" : "model"
      end

      def scope_directory(scope)
        "scopes/#{scope_kind_directory(scope)}/#{scope.key}"
      end

      def journal_path(scope)
        "#{scope_directory(scope)}/journal.jsonl"
      end

      def projection_path(scope)
        "#{scope_directory(scope)}/current.json"
      end

      def load_replay(scope, recover_torn:, publish_projection:)
        relative = journal_path(scope)
        bytes = @directory.read(relative, max_bytes: MAX_JOURNAL_BYTES, missing: true)
        return fresh_replay(scope, publish_projection: publish_projection) if bytes.nil? || bytes.empty?

        original = bytes
        unless bytes.end_with?("\n")
          prefix_end = bytes.rindex("\n")
          suffix = prefix_end ? bytes.byteslice((prefix_end + 1)..) : bytes
          begin
            JSON.parse(suffix)
            raise JournalCorruption.new(
              scope: scope,
              bytes: original,
              last_circuit: Circuit.closed(scope: scope)
            )
          rescue JSON::ParserError
            unless recover_torn
              raise JournalCorruption.new(
                scope: scope,
                bytes: original,
                last_circuit: Circuit.closed(scope: scope)
              )
            end
            bytes = prefix_end ? bytes.byteslice(0..prefix_end) : "".b
            @directory.atomic_write(
              relative,
              bytes,
              mode: 0o600,
              expected_digest: ProviderHealth.digest(original),
              max_existing_bytes: MAX_JOURNAL_BYTES
            )
          end
        end

        events = []
        circuit = nil
        bytes.each_line.with_index(1) do |line, sequence|
          begin
            data = JSON.parse(line)
            event = Event.from_h(data)
            raise Unavailable, "scope mismatch" unless event.scope == scope
            raise Unavailable, "sequence gap" unless event.sequence == sequence
            if circuit.nil?
              if event.kind != "reset" && (event.journal_epoch != 0 || event.previous_generation != 0)
                raise Unavailable, "invalid journal genesis"
              end
              circuit = Circuit.closed(
                scope: scope,
                generation: event.previous_generation,
                journal_epoch: event.journal_epoch
              )
            end
            circuit = event.apply(circuit)
            events << event
          rescue JSON::ParserError, Error, KeyError, TypeError, ArgumentError
            raise JournalCorruption.new(
              scope: scope,
              bytes: original,
              last_circuit: circuit || Circuit.closed(scope: scope)
            )
          end
        end
        if events.length > MAX_JOURNAL_EVENTS ||
           events.map(&:event_id).uniq.length != events.length ||
           events.map(&:idempotency_key).uniq.length != events.length
          raise JournalCorruption.new(
            scope: scope,
            bytes: original,
            last_circuit: circuit || Circuit.closed(scope: scope)
          )
        end
        circuit ||= Circuit.closed(scope: scope)
        replay = Replay.new(
          circuit: circuit,
          events: events.freeze,
          bytes: bytes.freeze,
          existed: true
        )
        publish_projection(replay) if publish_projection
        replay
      rescue Hive::ConfigError
        raise
      rescue JournalCorruption
        raise
      rescue StandardError
        raise JournalCorruption.new(
          scope: scope,
          bytes: bytes || "".b,
          last_circuit: Circuit.closed(scope: scope)
        )
      end

      def fresh_replay(scope, publish_projection:)
        replay = Replay.new(
          circuit: Circuit.closed(scope: scope),
          events: [].freeze,
          bytes: "".b.freeze,
          existed: false
        )
        publish_projection(replay) if publish_projection
        replay
      end

      def publish_projection(replay)
        content = "#{ProviderHealth.canonical_json(replay.circuit.to_h)}\n"
        relative = projection_path(replay.circuit.scope)
        existing = @directory.read(relative, max_bytes: MAX_JOURNAL_BYTES, missing: true)
        return if existing == content

        @directory.atomic_write(relative, content, mode: 0o600)
      end

      def append_transition(replay, kind:, idempotency_key:, payload:)
        duplicate = duplicate_result(replay, idempotency_key)
        return duplicate if duplicate

        event = Event.new(
          event_id: SecureRandom.uuid,
          sequence: replay.sequence + 1,
          scope: replay.circuit.scope,
          journal_epoch: replay.circuit.journal_epoch,
          kind: kind,
          occurred_at: current_time,
          idempotency_key: idempotency_key,
          expected_generation: replay.circuit.generation,
          previous_generation: replay.circuit.generation,
          resulting_generation: replay.circuit.generation + 1,
          payload: payload
        )
        persist_event(replay, event)
      end

      def append_rejection(replay, reason:, idempotency_key:)
        event = Event.new(
          event_id: SecureRandom.uuid,
          sequence: replay.sequence + 1,
          scope: replay.circuit.scope,
          journal_epoch: replay.circuit.journal_epoch,
          kind: "evidence_rejected",
          occurred_at: current_time,
          idempotency_key: idempotency_key,
          expected_generation: replay.circuit.generation,
          previous_generation: replay.circuit.generation,
          resulting_generation: replay.circuit.generation,
          payload: { "reason" => reason }
        )
        persist_event(replay, event, status: "rejected", reason: reason)
      end

      def persist_event(replay, event, status: "accepted", reason: nil)
        circuit = event.apply(replay.circuit)
        line = "#{ProviderHealth.canonical_json(event.to_h)}\n"
        bytes = replay.bytes + line
        raise Unavailable, "provider-health journal is full" if bytes.bytesize > MAX_JOURNAL_BYTES

        @directory.atomic_write(
          journal_path(event.scope),
          bytes,
          mode: 0o600,
          expected_digest: replay.existed ? ProviderHealth.digest(replay.bytes) : nil,
          max_existing_bytes: MAX_JOURNAL_BYTES
        )
        next_replay = Replay.new(
          circuit: circuit,
          events: (replay.events + [ event ]).freeze,
          bytes: bytes.freeze,
          existed: true
        )
        publish_projection(next_replay)
        audit = event.payload["audit"] && Audit::Receipt.from_h(event.payload.fetch("audit"))
        MutationResult.new(
          status: status,
          reason: reason || event.kind,
          previous: replay.circuit,
          current: circuit,
          generation: circuit.generation,
          event_id: event.event_id,
          audit_receipt: audit
        )
      end

      def duplicate_result(replay, idempotency_key)
        event = replay.events.find { |candidate| candidate.idempotency_key == idempotency_key }
        return nil unless event

        MutationResult.new(
          status: "duplicate",
          reason: "duplicate_evidence",
          previous: replay.circuit,
          current: replay.circuit,
          generation: replay.circuit.generation,
          event_id: event.event_id,
          audit_receipt: event.payload["audit"] && Audit::Receipt.from_h(event.payload.fetch("audit"))
        )
      end

      def evidence_rejection(evidence:, attempt:, expected_generation:, circuit:)
        return "stale_generation" unless Integer(expected_generation) == circuit.generation
        return "fenced_attempt" unless evidence.attempt_id == attempt.attempt_id
        return "fenced_attempt" unless evidence.route == attempt.route
        rejection = current_attempt_rejection(attempt)
        return rejection if rejection

        nil
      rescue ArgumentError, TypeError
        "stale_generation"
      end

      def normalize_terminal_receipt(receipt, attempt_id:)
        unless receipt.is_a?(Hash) && receipt.keys.map(&:to_s).sort == TERMINAL_RECEIPT_FIELDS.sort
          raise InvalidMutation, "terminal receipt identity has unexpected fields"
        end
        value = receipt.to_h { |key, child| [ key.to_s, child ] }
        unless value.fetch("attempt_id") == attempt_id
          raise InvalidMutation, "terminal receipt attempt does not match"
        end
        ProviderHealth.identifier(value.fetch("attempt_id"), "terminal attempt")
        %w[receipt_version terminal_lease_version].each do |field|
          ProviderHealth.nonnegative_integer(value.fetch(field), field.tr("_", " "))
        end
        ProviderHealth.deep_freeze(value)
      rescue KeyError
        raise InvalidMutation, "terminal receipt identity is incomplete"
      end

      def valid_current_attempt?(attempt)
        current_attempt_rejection(attempt).nil?
      end

      def current_attempt_rejection(attempt)
        return nil unless @attempt_reader

        current = @attempt_reader.call(attempt.attempt_id)
        return "late_receipt" if current.nil?
        return current == attempt ? nil : "fenced_attempt" if current.is_a?(AttemptBinding)
        return "fenced_attempt" unless current.is_a?(Hash)

        value = current.to_h { |key, child| [ key.to_s, child ] }
        return "fenced_attempt" unless value["attempt_id"] == attempt.attempt_id
        return "superseded_generation" unless value["task_generation"] == attempt.task_generation
        return "fenced_attempt" unless value["ownership_fence"] == attempt.ownership_fence
        return "superseded_generation" if value["state"] == "superseded"
        return "fenced_attempt" if value["state"] == "fenced"
        return "late_receipt" if %w[archived deleted].include?(value["state"])

        nil
      rescue StandardError
        "fenced_attempt"
      end

      def matching_probe?(circuit, binding)
        circuit.journal_epoch == binding.journal_epoch &&
          circuit.generation == binding.claim_generation &&
          circuit.probe == binding.to_h
      end

      def blocker(scope, reason, inspection)
        {
          "scope" => scope.to_h,
          "reason" => reason,
          "generation" => inspection.generation,
          "journal_epoch" => inspection.journal_epoch
        }
      end

      def unavailable_inspection(corruption)
        fingerprint = ProviderHealth.digest(corruption.bytes)
        token = CorruptionToken.new(
          scope: corruption.scope,
          journal_epoch: corruption.last_circuit.journal_epoch,
          corruption_fingerprint: fingerprint,
          last_verified_generation: corruption.last_circuit.generation
        )
        Inspection.new(
          status: "unavailable",
          scope: corruption.scope,
          circuit: nil,
          generation: corruption.last_circuit.generation,
          journal_epoch: corruption.last_circuit.journal_epoch,
          unavailable_reason: "health_state_unavailable",
          corruption_token: token,
          artifact_reference: {
            "path" => journal_path(corruption.scope),
            "size" => corruption.bytes.bytesize,
            "sha256" => fingerprint
          }
        )
      end

      def operator_mutation(scope:, expected_generation:, actor:, reason:, action:)
        require_scope!(scope)
        actor_value = Audit.validate_actor(actor)
        reason_value = Audit.validate_reason(reason)
        with_mutation_lock do
          replay = load_replay(scope, recover_torn: true, publish_projection: true)
          enforce_generation!(replay.circuit, expected_generation)
          append_operator_transition(
            replay,
            action: action,
            actor: actor_value,
            reason: reason_value
          )
        end
      end

      def append_operator_transition(replay, action:, actor:, reason:)
        circuit = replay.circuit
        event_id = SecureRandom.uuid
        now = current_time
        manual_block = case action
        when "block"
          { "actor" => actor, "reason" => reason, "blocked_at" => now.iso8601(6) }
        when "unblock"
          nil
        when "reset"
          circuit.manual_block
        else
          raise InvalidMutation, "unknown operator health mutation"
        end
        predicted = case action
        when "block" then circuit.with(generation: circuit.generation + 1, manual_block: manual_block)
        when "unblock" then circuit.with(generation: circuit.generation + 1, manual_block: nil)
        when "reset"
          circuit.with(
            generation: circuit.generation + 1,
            automatic_state: "closed",
            eligible_at: nil,
            evidence: nil,
            probe: nil
          )
        end
        audit = Audit::Receipt.new(
          actor: actor,
          reason: reason,
          target: circuit.scope,
          action: action,
          occurred_at: now,
          previous_state: audit_state(circuit),
          new_state: audit_state(predicted),
          generation: predicted.generation,
          event_id: event_id,
          artifact_reference: nil
        )
        kind = {
          "block" => "manual_blocked",
          "unblock" => "manual_unblocked",
          "reset" => "reset"
        }.fetch(action)
        event = Event.new(
          event_id: event_id,
          sequence: replay.sequence + 1,
          scope: circuit.scope,
          journal_epoch: circuit.journal_epoch,
          kind: kind,
          occurred_at: now,
          idempotency_key: ProviderHealth.digest(
            "operator" => actor,
            "action" => action,
            "scope" => circuit.scope.to_h,
            "expected_generation" => circuit.generation,
            "reason" => reason
          ),
          expected_generation: circuit.generation,
          previous_generation: circuit.generation,
          resulting_generation: circuit.generation + 1,
          payload: { "manual_block" => manual_block, "audit" => audit.to_h }
        )
        persist_event(replay, event)
      end

      def audit_state(circuit)
        {
          "automatic_state" => circuit.automatic_state,
          "manual_blocked" => circuit.blocked?,
          "probe_owned" => circuit.probe_owned?,
          "generation" => circuit.generation,
          "journal_epoch" => circuit.journal_epoch
        }
      end

      def enforce_generation!(circuit, expected_generation)
        expected = Integer(expected_generation)
        return if circuit.generation == expected

        raise StaleGeneration, "provider-health generation changed; inspect again"
      rescue ArgumentError, TypeError
        raise StaleGeneration, "provider-health expected generation is invalid"
      end

      def reset_corruption(corruption, token:, actor:, reason:)
        unless token.is_a?(CorruptionToken) && token.scope == corruption.scope &&
               token.journal_epoch == corruption.last_circuit.journal_epoch &&
               token.corruption_fingerprint == ProviderHealth.digest(corruption.bytes) &&
               token.last_verified_generation == corruption.last_circuit.generation
          raise StaleGeneration, "provider-health corruption token is stale"
        end
        old = corruption.last_circuit
        new_epoch = old.journal_epoch + 1
        event_id = SecureRandom.uuid
        now = current_time
        predicted = Circuit.closed(
          scope: old.scope,
          generation: old.generation + 1,
          journal_epoch: new_epoch
        ).with(manual_block: old.manual_block)
        quarantine = "quarantine/#{scope_kind_directory(old.scope)}/#{old.scope.key}/" \
                     "#{old.journal_epoch}-#{token.corruption_fingerprint}.jsonl"
        quarantine_reference = {
          "path" => quarantine,
          "size" => corruption.bytes.bytesize,
          "sha256" => token.corruption_fingerprint
        }
        audit = Audit::Receipt.new(
          actor: actor,
          reason: reason,
          target: old.scope,
          action: "reset",
          occurred_at: now,
          previous_state: audit_state(old),
          new_state: audit_state(predicted),
          generation: predicted.generation,
          event_id: event_id,
          artifact_reference: quarantine_reference
        )
        event = Event.new(
          event_id: event_id,
          sequence: 1,
          scope: old.scope,
          journal_epoch: new_epoch,
          kind: "reset",
          occurred_at: now,
          idempotency_key: ProviderHealth.digest(
            "corruption_token" => token.to_h,
            "actor" => actor,
            "reason" => reason
          ),
          expected_generation: old.generation,
          previous_generation: old.generation,
          resulting_generation: old.generation + 1,
          payload: { "manual_block" => old.manual_block, "audit" => audit.to_h }
        )
        @directory.atomic_write(quarantine, corruption.bytes, mode: 0o600)
        line = "#{ProviderHealth.canonical_json(event.to_h)}\n"
        @directory.atomic_write(
          journal_path(old.scope),
          line,
          mode: 0o600,
          expected_digest: token.corruption_fingerprint,
          max_existing_bytes: MAX_JOURNAL_BYTES
        )
        replay = Replay.new(
          circuit: event.apply(
            Circuit.closed(
              scope: old.scope,
              generation: old.generation,
              journal_epoch: new_epoch
            )
          ),
          events: [ event ].freeze,
          bytes: line.freeze,
          existed: true
        )
        publish_projection(replay)
        MutationResult.new(
          status: "accepted",
          reason: "reset",
          previous: old,
          current: replay.circuit,
          generation: replay.circuit.generation,
          event_id: event_id,
          audit_receipt: audit
        )
      end

      def intent_path(intent_id)
        "intents/#{ProviderHealth.digest(intent_id)}.json"
      end

      def intent_exists?(intent_id)
        !@directory.read(intent_path(intent_id), max_bytes: MAX_INTENT_BYTES, missing: true).nil?
      end

      def persist_intent(intent, bindings)
        payload = {
          "schema" => "hive-provider-health-probe-intent",
          "schema_version" => 1,
          "intent" => intent.to_h,
          "bindings" => bindings.map(&:to_h)
        }
        @directory.atomic_write(
          intent_path(intent.intent_id),
          "#{ProviderHealth.canonical_json(payload)}\n",
          mode: 0o600
        )
      end

      def remove_intent(intent_id)
        relative = intent_path(intent_id)
        bytes = @directory.read(relative, max_bytes: MAX_INTENT_BYTES, missing: true)
        return false unless bytes

        @directory.unlink(
          relative,
          expected_digest: ProviderHealth.digest(bytes),
          max_bytes: MAX_INTENT_BYTES
        )
      end

      def load_intents
        entries = []
        @directory.each_child("intents", missing: true) do |name|
          next unless name.end_with?(".json")

          bytes = @directory.read("intents/#{name}", max_bytes: MAX_INTENT_BYTES)
          entries << parse_intent(bytes)
        end
        entries.sort_by { |entry| entry.fetch(:intent).intent_id }.freeze
      rescue JSON::ParserError, KeyError, InvalidMutation, InvalidScope, TypeError
        raise Unavailable, "provider-health probe intent state is unavailable"
      end

      def parse_intent(bytes)
        data = JSON.parse(bytes)
        unless data.is_a?(Hash) && data.keys.sort == %w[bindings intent schema schema_version] &&
               data["schema"] == "hive-provider-health-probe-intent" && data["schema_version"] == 1
          raise InvalidMutation, "probe intent schema is invalid"
        end
        intent_data = data.fetch("intent")
        unless intent_data.is_a?(Hash) && intent_data.keys.sort == %w[
          attempt_id intent_id ownership_fence requirements task_generation
        ]
          raise InvalidMutation, "probe intent has unexpected fields"
        end
        requirements = intent_data.fetch("requirements").map do |raw|
          unless raw.is_a?(Hash) && raw.keys.sort == %w[
            journal_epoch observed_generation scope
          ]
            raise InvalidMutation, "probe requirement has unexpected fields"
          end
          ProbeRequirement.new(
            scope: scope_from_h(raw.fetch("scope")),
            journal_epoch: raw.fetch("journal_epoch"),
            observed_generation: raw.fetch("observed_generation")
          )
        end
        intent = ProbeIntent.new(
          intent_id: intent_data.fetch("intent_id"),
          attempt_id: intent_data.fetch("attempt_id"),
          task_generation: intent_data.fetch("task_generation"),
          ownership_fence: intent_data.fetch("ownership_fence"),
          requirements: requirements
        )
        bindings = data.fetch("bindings").map { |raw| probe_binding_from_h(raw) }
        unless bindings.map(&:scope) == requirements.map(&:scope)
          raise InvalidMutation, "probe intent bindings do not match requirements"
        end
        { intent: intent, bindings: bindings.freeze }.freeze
      end

      def scope_from_h(data)
        ProviderHealth.scope_from_h(data)
      end

      def probe_binding_from_h(data)
        unless data.is_a?(Hash) && data.keys.sort == %w[
          attempt_id claim_generation journal_epoch observed_generation
          ownership_fence scope task_generation
        ]
          raise InvalidMutation, "probe binding has unexpected fields"
        end
        ProbeBinding.new(
          scope: scope_from_h(data.fetch("scope")),
          journal_epoch: data.fetch("journal_epoch"),
          observed_generation: data.fetch("observed_generation"),
          claim_generation: data.fetch("claim_generation"),
          attempt_id: data.fetch("attempt_id"),
          task_generation: data.fetch("task_generation"),
          ownership_fence: data.fetch("ownership_fence")
        )
      end

      def unresolved_intent?(scope, intents)
        intents.any? do |stored|
          stored.fetch(:bindings).any? { |binding| binding.scope == scope }
        end
      end

      def probe_claim_key(intent_id, binding)
        ProviderHealth.digest("intent_id" => intent_id, "probe_binding" => binding.to_h)
      end

      def reconcile_intent(stored)
        intent = stored.fetch(:intent)
        bindings = stored.fetch(:bindings)
        current = @attempt_reader&.call(intent.attempt_id)
        exact = attempt_matches_intent?(current, intent, bindings)
        live = exact && !terminal_attempt?(current)

        results = bindings.map do |binding|
          replay = load_replay(binding.scope, recover_torn: true, publish_projection: true)
          if live
            if matching_probe?(replay.circuit, binding)
              MutationResult.new(
                status: "duplicate",
                reason: "probe_already_claimed",
                previous: replay.circuit,
                current: replay.circuit,
                generation: replay.circuit.generation
              )
            elsif replay.circuit.generation == binding.observed_generation
              append_transition(
                replay,
                kind: "probe_claimed",
                idempotency_key: probe_claim_key(intent.intent_id, binding),
                payload: { "probe" => binding.to_h }
              )
            else
              raise Unavailable, "provider-health probe intent cannot be reconciled"
            end
          elsif matching_probe?(replay.circuit, binding)
            append_transition(
              replay,
              kind: "probe_reconciled",
              idempotency_key: ProviderHealth.digest(
                "intent_id" => intent.intent_id,
                "binding" => binding.to_h,
                "reconciled" => true
              ),
              payload: {
                "eligible_at" => (current_time + DEFAULT_COOLDOWN_SECONDS).iso8601(6),
                "receipt_identity" => ProviderHealth.digest(
                  "intent_id" => intent.intent_id, "attempt_state" => "not_live"
                )
              }
            )
          else
            MutationResult.new(
              status: "accepted",
              reason: "probe_intent_rolled_back",
              previous: replay.circuit,
              current: replay.circuit,
              generation: replay.circuit.generation
            )
          end
        end
        remove_intent(intent.intent_id)
        results.freeze
      end

      def attempt_matches_intent?(current, intent, bindings)
        expected_bindings = bindings.map(&:to_h)
        return false if current.nil?
        if current.is_a?(AttemptBinding)
          return current.attempt_id == intent.attempt_id &&
            current.task_generation == intent.task_generation &&
            current.ownership_fence == intent.ownership_fence &&
            current.probe_bindings.map(&:to_h) == expected_bindings
        end
        return false unless current.is_a?(Hash)

        value = current.to_h { |key, child| [ key.to_s, child ] }
        value["attempt_id"] == intent.attempt_id &&
          value["task_generation"] == intent.task_generation &&
          value["ownership_fence"] == intent.ownership_fence &&
          value["probe_bindings"] == expected_bindings
      end

      def terminal_attempt?(current)
        return false if current.is_a?(AttemptBinding)
        return false unless current.is_a?(Hash)

        %w[terminal lost cancelled fenced].include?(current["state"] || current[:state])
      end
    end
  end
end
