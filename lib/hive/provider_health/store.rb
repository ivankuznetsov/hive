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
      IDEMPOTENCY_SHARD_COUNT = 64
      MAX_IDEMPOTENCY_SHARD_BYTES = 2 * 1024 * 1024
      IDEMPOTENCY_SHARD_SCHEMA = "hive-provider-health-idempotency-shard"
      MAX_INTENT_BYTES = 64 * 1024
      MAX_INTENT_FILES = 1024
      INTENT_FILE_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}\.json\z/
      DEFAULT_COOLDOWN_SECONDS = 300
      TERMINAL_RECEIPT_FIELDS = %w[
        attempt_id receipt_version terminal_lease_version
      ].freeze

      Replay = Data.define(:circuit, :events, :bytes, :existed, :source_bytes) do
        def initialize(circuit:, events:, bytes:, existed:, source_bytes: bytes)
          super
        end

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
        %w[
          scopes/provider-account scopes/model intents quarantine quarantine/intents
          history/provider-account history/model idempotency/provider-account idempotency/model
        ].each do |relative|
          @directory.ensure_directory(relative)
        end
      end

      def inspect_scope(scope, now: current_time)
        inspect_scopes([ scope ], now: now).first
      end

      # Pure reporting snapshot. All requested scopes are sampled under one
      # host-global lock without repairing journals or publishing projections.
      def inspect_scopes(scopes, now: current_time)
        values = Array(scopes)
        values.each { |scope| require_scope!(scope) }
        with_mutation_lock do
          values.map do |scope|
            begin
              replay = load_replay(scope, recover_torn: false, publish_projection: false)
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
          end.freeze
        end
      rescue Unavailable, Hive::ManagedDirectory::UnsafeError
        values.map { |scope| unavailable_scope_inspection(scope) }.freeze
      end

      def evaluate_route(account_id:, model_id:, now: current_time)
        evaluate_routes(
          routes: [ { account_id: account_id, model_id: model_id } ],
          now: now
        ).first
      end

      # One immutable admission snapshot for an ordered route set. Probe
      # intents are scanned once and every unique enclosing scope is replayed
      # once under one host-global lock, even when many models share an
      # account. Results preserve the input route order.
      def evaluate_routes(routes:, now: current_time)
        route_scopes = normalize_route_scopes(routes)
        with_mutation_lock do
          intents = load_intents
          inspections_by_scope = route_scopes.flatten.uniq.to_h do |scope|
            begin
              replay = load_replay(scope, recover_torn: false, publish_projection: false)
              inspection = Inspection.new(
                status: "available",
                scope: scope,
                circuit: replay.circuit,
                generation: replay.circuit.generation,
                journal_epoch: replay.circuit.journal_epoch
              )
            rescue JournalCorruption => corruption
              inspection = unavailable_inspection(corruption)
            end
            [ scope, inspection ]
          end
          route_scopes.map do |scopes|
            route_evaluation(
              inspections: scopes.map { |scope| inspections_by_scope.fetch(scope) },
              intents: intents,
              now: now
            )
          end
        end.freeze
      rescue JournalCorruption => corruption
        unavailable_route_evaluations(route_scopes, corruption: corruption)
      rescue Unavailable, Hive::ManagedDirectory::UnsafeError
        unavailable_route_evaluations(route_scopes)
      end

      # Read-only bounded inspection for the global probe-intent substrate.
      # Corrupt files cannot be attributed to a scope safely, so routing stays
      # fail-closed until an operator quarantines the exact digest-addressed
      # artifact through reset_probe_intent.
      def inspect_probe_intents
        with_mutation_lock do
          entries, corruptions = scan_intents
          {
            "status" => corruptions.empty? ? "available" : "unavailable",
            "valid_count" => entries.length,
            "corruptions" => corruptions
          }.freeze
        end
      end

      def reset_probe_intent(intent_file:, corruption_fingerprint:, actor:, reason:)
        name = validate_intent_file!(intent_file)
        fingerprint = corruption_fingerprint.to_s
        unless fingerprint.match?(SHA256_PATTERN)
          raise InvalidMutation, "probe-intent corruption fingerprint is invalid"
        end
        actor_value = Audit.validate_actor(actor)
        reason_value = Audit.validate_reason(reason)

        with_mutation_lock do
          relative = "intents/#{name}"
          bytes = @directory.read(relative, max_bytes: MAX_INTENT_BYTES, missing: true)
          raise StaleGeneration, "probe-intent corruption token is stale" unless bytes
          unless ProviderHealth.digest(bytes) == fingerprint
            raise StaleGeneration, "probe-intent corruption token is stale"
          end
          begin
            parse_named_intent(name, bytes)
          rescue JSON::ParserError, KeyError, InvalidMutation, InvalidScope, TypeError
            # Expected: only an artifact that is still corrupt may be reset.
          else
            raise StaleGeneration, "probe-intent artifact is no longer corrupt"
          end

          event_id = SecureRandom.uuid
          quarantine = "quarantine/intents/#{name.delete_suffix('.json')}/#{fingerprint}.json"
          reference = {
            "path" => quarantine,
            "size" => bytes.bytesize,
            "sha256" => fingerprint
          }.freeze
          audit = {
            "actor" => actor_value,
            "reason" => reason_value,
            "action" => "reset_probe_intent",
            "occurred_at" => current_time.iso8601(6),
            "event_id" => event_id,
            "artifact_reference" => reference
          }.freeze
          @directory.atomic_write(quarantine, bytes, mode: 0o600)
          @directory.atomic_write(
            "#{quarantine}.receipt.json",
            "#{ProviderHealth.canonical_json(audit)}\n",
            mode: 0o600
          )
          @directory.unlink(
            relative,
            expected_digest: fingerprint,
            max_bytes: MAX_INTENT_BYTES
          )
          {
            "status" => "accepted",
            "reason" => "reset_probe_intent",
            "intent_file" => name,
            "event_id" => event_id,
            "audit" => audit
          }.freeze
        end
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
      rescue Unavailable, Hive::ManagedDirectory::UnsafeError
        raise StaleGeneration, "provider-health route observation is unavailable"
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
          reconcile_intents_for_scope(scope)
          replay = load_replay(scope, recover_torn: true, publish_projection: true)
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
      rescue JournalCorruption, Hive::ManagedDirectory::UnsafeError
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
        return fresh_replay(scope, publish_projection: publish_projection) if bytes.nil?

        original = bytes
        if bytes.empty?
          raise JournalCorruption.new(
            scope: scope,
            bytes: original,
            last_circuit: Circuit.closed(scope: scope)
          )
        end
        # A final record without its newline, or a partial final record after
        # the last newline, is a recoverable append tear. Replay a complete
        # record with a virtual newline or discard only the malformed suffix.
        # The original bytes remain the CAS source so the next mutation
        # replaces the torn journal and appends its event in one atomic write.
        unless bytes.end_with?("\n")
          prefix_end = bytes.rindex("\n")
          suffix = prefix_end ? bytes.byteslice((prefix_end + 1)..) : bytes
          begin
            JSON.parse(suffix)
            bytes = "#{bytes}\n"
          rescue JSON::ParserError
            unless prefix_end
              raise JournalCorruption.new(
                scope: scope,
                bytes: original,
                last_circuit: Circuit.closed(scope: scope)
              )
            end
            bytes = bytes.byteslice(0..prefix_end)
          end
        end

        events = []
        event_ids = {}
        idempotency_keys = {}
        circuit = nil
        bytes.each_line.with_index(1) do |line, sequence|
          begin
            data = JSON.parse(line)
            event = Event.from_h(data)
            raise Unavailable, "scope mismatch" unless event.scope == scope
            raise Unavailable, "sequence gap" unless event.sequence == sequence
            if events.length >= MAX_JOURNAL_EVENTS || event_ids.key?(event.event_id) ||
               idempotency_keys.key?(event.idempotency_key)
              raise Unavailable, "duplicate or excessive journal event"
            end
            if circuit.nil?
              unless %w[reset snapshot].include?(event.kind) ||
                     (event.journal_epoch == 0 && event.previous_generation == 0)
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
            event_ids[event.event_id] = true
            idempotency_keys[event.idempotency_key] = true
          rescue JSON::ParserError, Error, KeyError, TypeError, ArgumentError
            raise JournalCorruption.new(
              scope: scope,
              bytes: original,
              last_circuit: circuit || Circuit.closed(scope: scope)
            )
          end
        end
        circuit ||= Circuit.closed(scope: scope)
        replay = Replay.new(
          circuit: circuit,
          events: events.freeze,
          bytes: bytes.freeze,
          existed: true,
          source_bytes: original.freeze
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
          existed: false,
          source_bytes: "".b.freeze
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
        line = "#{ProviderHealth.canonical_json(event.to_h)}\n"
        bytes = replay.bytes + line
        if replay.sequence >= MAX_JOURNAL_EVENTS || bytes.bytesize > MAX_JOURNAL_BYTES
          replay = compact_replay(replay)
          event = resequence_event(event, replay.sequence + 1)
          line = "#{ProviderHealth.canonical_json(event.to_h)}\n"
          bytes = replay.bytes + line
        end
        if replay.sequence >= MAX_JOURNAL_EVENTS || bytes.bytesize > MAX_JOURNAL_BYTES
          raise Unavailable, "provider-health journal event exceeds the bounded active journal"
        end
        circuit = event.apply(replay.circuit)

        @directory.atomic_write(
          journal_path(event.scope),
          bytes,
          mode: 0o600,
          expected_digest: replay.existed ? ProviderHealth.digest(replay.source_bytes) : nil,
          max_existing_bytes: MAX_JOURNAL_BYTES
        )
        next_replay = Replay.new(
          circuit: circuit,
          events: (replay.events + [ event ]).freeze,
          bytes: bytes.freeze,
          existed: true,
          source_bytes: bytes.freeze
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
        compacted = nil
        unless event
          compacted = compacted_idempotency(replay.circuit.scope, idempotency_key)
          return nil unless compacted
        end

        MutationResult.new(
          status: "duplicate",
          reason: "duplicate_evidence",
          previous: replay.circuit,
          current: replay.circuit,
          generation: replay.circuit.generation,
          event_id: event&.event_id || compacted.fetch("event_id"),
          audit_receipt: event&.payload&.fetch("audit", nil) &&
            Audit::Receipt.from_h(event.payload.fetch("audit"))
        )
      end

      def compact_replay(replay)
        scope = replay.circuit.scope
        persist_compacted_idempotency(replay)
        archive_compacted_journal(replay)
        snapshot = Event.new(
          event_id: SecureRandom.uuid,
          sequence: 1,
          scope: scope,
          journal_epoch: replay.circuit.journal_epoch,
          kind: "snapshot",
          occurred_at: current_time,
          idempotency_key: ProviderHealth.digest(
            "snapshot" => ProviderHealth.digest(replay.bytes),
            "scope" => scope.to_h,
            "generation" => replay.circuit.generation
          ),
          expected_generation: replay.circuit.generation,
          previous_generation: replay.circuit.generation,
          resulting_generation: replay.circuit.generation,
          payload: { "state" => snapshot_state(replay.circuit) }
        )
        line = "#{ProviderHealth.canonical_json(snapshot.to_h)}\n"
        @directory.atomic_write(
          journal_path(scope),
          line,
          mode: 0o600,
          expected_digest: replay.existed ? ProviderHealth.digest(replay.source_bytes) : nil,
          max_existing_bytes: MAX_JOURNAL_BYTES
        )
        circuit = snapshot.apply(
          Circuit.closed(
            scope: scope,
            generation: replay.circuit.generation,
            journal_epoch: replay.circuit.journal_epoch
          )
        )
        Replay.new(
          circuit: circuit,
          events: [ snapshot ].freeze,
          bytes: line.freeze,
          existed: true,
          source_bytes: line.freeze
        )
      end

      def snapshot_state(circuit)
        {
          "automatic_state" => circuit.automatic_state,
          "eligible_at" => circuit.eligible_at,
          "evidence" => circuit.evidence,
          "last_event_id" => circuit.last_event_id,
          "manual_block" => circuit.manual_block,
          "probe" => circuit.probe
        }
      end

      def resequence_event(event, sequence)
        Event.new(
          event_id: event.event_id,
          sequence: sequence,
          scope: event.scope,
          journal_epoch: event.journal_epoch,
          kind: event.kind,
          occurred_at: event.occurred_at,
          idempotency_key: event.idempotency_key,
          expected_generation: event.expected_generation,
          previous_generation: event.previous_generation,
          resulting_generation: event.resulting_generation,
          payload: event.payload
        )
      end

      def persist_compacted_idempotency(replay)
        directory = idempotency_directory(replay.circuit.scope)
        shard_directory = "#{directory}/shards"
        @directory.ensure_directory(shard_directory)
        replay.events.group_by do |event|
          idempotency_shard_path(replay.circuit.scope, event.idempotency_key)
        end.each do |relative, events|
          existing = @directory.read(
            relative,
            max_bytes: MAX_IDEMPOTENCY_SHARD_BYTES,
            missing: true
          )
          entries = existing ? parse_idempotency_shard(existing) : {}
          events.each do |event|
            prior = entries[event.idempotency_key]
            if prior && prior != event.event_id
              raise Unavailable, "provider-health compacted idempotency index is unavailable"
            end
            entries[event.idempotency_key] = event.event_id
          end
          content = "#{ProviderHealth.canonical_json(
            "schema" => IDEMPOTENCY_SHARD_SCHEMA,
            "schema_version" => 1,
            "entries" => entries.sort.to_h
          )}\n"
          if content.bytesize > MAX_IDEMPOTENCY_SHARD_BYTES
            raise Unavailable, "provider-health compacted idempotency shard is full"
          end
          next if existing == content

          @directory.atomic_write(
            relative,
            content,
            mode: 0o600,
            expected_digest: existing && ProviderHealth.digest(existing),
            max_existing_bytes: MAX_IDEMPOTENCY_SHARD_BYTES
          )
        end
      end

      def compacted_idempotency(scope, idempotency_key)
        value = idempotency_key.to_s
        return nil unless SHA256_PATTERN.match?(value)

        shard = @directory.read(
          idempotency_shard_path(scope, value),
          max_bytes: MAX_IDEMPOTENCY_SHARD_BYTES,
          missing: true
        )
        if shard
          event_id = parse_idempotency_shard(shard)[value]
          if event_id
            return {
              "idempotency_key" => value,
              "event_id" => event_id
            }.freeze
          end
        end

        bytes = @directory.read(
          "#{idempotency_directory(scope)}/#{value}.json",
          max_bytes: 512,
          missing: true
        )
        return nil unless bytes

        data = JSON.parse(bytes)
        unless data.is_a?(Hash) && data.keys.sort == %w[event_id idempotency_key] &&
               data.fetch("idempotency_key") == value
          raise Unavailable, "provider-health compacted idempotency index is unavailable"
        end
        ProviderHealth.identifier(data.fetch("event_id"), "compacted event")
        data.freeze
      rescue JSON::ParserError, KeyError, InvalidMutation
        raise Unavailable, "provider-health compacted idempotency index is unavailable"
      end

      def parse_idempotency_shard(bytes)
        data = JSON.parse(bytes)
        unless data.is_a?(Hash) && data.keys.sort == %w[entries schema schema_version] &&
               data.fetch("schema") == IDEMPOTENCY_SHARD_SCHEMA &&
               data.fetch("schema_version") == 1 && data.fetch("entries").is_a?(Hash)
          raise Unavailable, "provider-health compacted idempotency index is unavailable"
        end
        data.fetch("entries").each_with_object({}) do |(key, event_id), entries|
          unless SHA256_PATTERN.match?(key.to_s)
            raise Unavailable, "provider-health compacted idempotency index is unavailable"
          end
          entries[key] = ProviderHealth.identifier(event_id, "compacted event")
        end
      rescue JSON::ParserError, KeyError, InvalidMutation
        raise Unavailable, "provider-health compacted idempotency index is unavailable"
      end

      def archive_compacted_journal(replay)
        scope = replay.circuit.scope
        directory = "history/#{scope_kind_directory(scope)}/#{scope.key}"
        @directory.ensure_directory(directory)
        digest = ProviderHealth.digest(replay.bytes)
        relative = "#{directory}/#{replay.circuit.journal_epoch}-" \
                   "#{replay.circuit.generation}-#{digest}.jsonl"
        existing = @directory.read(relative, max_bytes: MAX_JOURNAL_BYTES, missing: true)
        if existing && existing != replay.bytes
          raise Unavailable, "provider-health compacted journal archive is unavailable"
        end
        @directory.atomic_write(relative, replay.bytes, mode: 0o600) unless existing
      end

      def idempotency_directory(scope)
        "idempotency/#{scope_kind_directory(scope)}/#{scope.key}"
      end

      def idempotency_shard_path(scope, idempotency_key)
        shard = idempotency_key.to_s.byteslice(0, 2).to_i(16) % IDEMPOTENCY_SHARD_COUNT
        "#{idempotency_directory(scope)}/shards/#{format('%02x', shard)}.json"
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

      def normalize_route_scopes(routes)
        values = Array(routes)
        raise InvalidMutation, "provider-health route set is empty" if values.empty?

        values.map do |route|
          unless route.is_a?(Hash)
            raise InvalidMutation, "provider-health route must contain account_id and model_id"
          end
          account_id = route.key?(:account_id) ? route.fetch(:account_id) : route.fetch("account_id")
          model_id = route.key?(:model_id) ? route.fetch(:model_id) : route.fetch("model_id")
          [
            Scope.provider_account(account_id: account_id),
            Scope.model(account_id: account_id, model_id: model_id)
          ].freeze
        end.freeze
      rescue KeyError
        raise InvalidMutation, "provider-health route must contain account_id and model_id"
      end

      def route_evaluation(inspections:, intents:, now:)
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
            blockers << blocker(inspection.scope, "circuit_open", inspection)
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

      def unavailable_route_evaluations(route_scopes, corruption: nil)
        route_scopes.map do |scopes|
          inspections = scopes.map do |scope|
            if corruption && corruption.scope == scope
              unavailable_inspection(corruption)
            else
              unavailable_scope_inspection(scope)
            end
          end
          route_evaluation(inspections: inspections, intents: [], now: current_time)
        end.freeze
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

      def unavailable_scope_inspection(scope)
        Inspection.new(
          status: "unavailable",
          scope: scope,
          circuit: nil,
          generation: 0,
          journal_epoch: 0,
          unavailable_reason: "health_state_unavailable"
        )
      end

      def operator_mutation(scope:, expected_generation:, actor:, reason:, action:)
        require_scope!(scope)
        actor_value = Audit.validate_actor(actor)
        reason_value = Audit.validate_reason(reason)
        with_mutation_lock do
          replay = load_replay(scope, recover_torn: true, publish_projection: true)
          enforce_generation!(replay.circuit, expected_generation)
          reconcile_intents_for_scope(scope)
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
        when "block"
          circuit.with(generation: circuit.generation + 1, manual_block: manual_block, probe: nil)
        when "unblock"
          circuit.with(generation: circuit.generation + 1, manual_block: nil, probe: nil)
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
          existed: true,
          source_bytes: line.freeze
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
        entries, corruptions = scan_intents
        unless corruptions.empty?
          raise Unavailable, "provider-health probe intent state is unavailable"
        end
        entries
      end

      def scan_intents
        entries = []
        corruptions = []
        @directory.each_child("intents", missing: true) do |name|
          next unless name.end_with?(".json")
          if entries.length + corruptions.length >= MAX_INTENT_FILES
            raise Unavailable, "provider-health probe intent state is unavailable"
          end

          bytes = @directory.read("intents/#{name}", max_bytes: MAX_INTENT_BYTES)
          begin
            entries << parse_named_intent(name, bytes)
          rescue JSON::ParserError, KeyError, InvalidMutation, InvalidScope, TypeError
            corruptions << intent_corruption(name, bytes)
          end
        end
        [
          entries.sort_by { |entry| entry.fetch(:intent).intent_id }.freeze,
          corruptions.sort_by { |entry| entry.fetch("intent_file") }.freeze
        ].freeze
      end

      def parse_named_intent(name, bytes)
        parsed = parse_intent(bytes)
        unless name == File.basename(intent_path(parsed.fetch(:intent).intent_id))
          raise InvalidMutation, "probe intent filename does not match its identity"
        end
        parsed
      end

      def intent_corruption(name, bytes)
        fingerprint = ProviderHealth.digest(bytes)
        {
          "intent_file" => name.freeze,
          "corruption_fingerprint" => fingerprint.freeze,
          "artifact_reference" => {
            "path" => "intents/#{name}".freeze,
            "size" => bytes.bytesize,
            "sha256" => fingerprint.freeze
          }.freeze
        }.freeze
      end

      def validate_intent_file!(value)
        name = value.to_s
        unless name.match?(INTENT_FILE_PATTERN) && name != "." && name != ".."
          raise InvalidMutation, "probe-intent file token is invalid"
        end
        name.freeze
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

      def reconcile_intents_for_scope(scope)
        load_intents.select do |stored|
          stored.fetch(:bindings).any? { |binding| binding.scope == scope }
        end.each { |stored| reconcile_intent(stored) }
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
              MutationResult.new(
                status: "accepted",
                reason: "probe_intent_fenced",
                previous: replay.circuit,
                current: replay.circuit,
                generation: replay.circuit.generation
              )
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
