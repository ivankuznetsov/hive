require "digest"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/base_state_store"
require "hive/patrol/effect_gateway"
require "hive/modules/migration/occurrence_journal"
require "hive/modules/migration/patrol_evidence"

module Hive
  module Patrol
    class StateStore < BaseStateStore
      def initialize(project_root, hive_state_path: nil)
        super(
          project_root,
          state_directory: "patrol",
          collections: %w[features findings patches reports runs],
          hive_state_path: hive_state_path
        )
        @occurrence_store = Hive::Modules::Migration::OccurrenceJournal.new(
          File.join(root, "occurrences"), module_name: "patrol"
        )
      end

      def configure_effect_gateway!(capture:, evidence_store:, config_loader:,
                                    capability_checker:, module_execution: nil,
                                    gateway_factory: nil)
        @effect_capture = capture
        reserve_occurrence!(capture)
        @effect_gateway_options = {
          project_root: project_root,
          hive_state_path: hive_state_path,
          evidence_store: evidence_store,
          delivery_store: self,
          config_loader: config_loader,
          capability_checker: capability_checker,
          module_execution: module_execution
        }.freeze
        @effect_gateway_factory = gateway_factory
        @state_effect_gateway = effect_gateway_for(capture)
        self
      end

      def configured_effect_gateway!(capture: @effect_capture)
        unless @state_effect_gateway && capture &&
               @effect_capture&.occurrence_id == capture.occurrence_id
          raise Hive::ConfigError,
                "patrol state effect gateway is unavailable"
        end

        @state_effect_gateway
      end

      def reserve_occurrence!(capture, now: Time.now.utc)
        @occurrence_store.reserve!(capture, now: now)
      end

      def reserve_attempt_occurrence!(reservation_id, window_started_at:,
                                      now: Time.now.utc,
                                      &capture_builder)
        @occurrence_store.reserve_attempt!(
          reservation_id,
          window_started_at: window_started_at,
          now: now,
          &capture_builder
        )
      end

      def occurrence(occurrence_id)
        @occurrence_store.fetch(occurrence_id)
      end

      def occurrence_capture(occurrence_id)
        record = occurrence(occurrence_id)
        return nil unless record

        Hive::Modules::Migration::PatrolCapture.from_h(
          record.fetch("provisional_capture")
        )
      end

      def each_reserved_occurrence(&block)
        return @occurrence_store.each_reserved unless block

        @occurrence_store.each_reserved(&block)
      end

      def each_projection_pending_occurrence(&block)
        return @occurrence_store.each_projection_pending unless block

        @occurrence_store.each_projection_pending(&block)
      end

      def each_recovery_active_occurrence(&block)
        return @occurrence_store.each_recovery_active unless block

        @occurrence_store.each_recovery_active(&block)
      end

      def recovery_active? = @occurrence_store.recovery_active?

      def rebuild_recovery_index!
        @occurrence_store.rebuild_recovery_index!
      end

      def each_occurrence(&block)
        return @occurrence_store.each_record unless block

        @occurrence_store.each_record(&block)
      end

      def finalize_occurrence!(capture:, event: nil, evidence_store:,
                               event_publisher: nil, project_entry: nil,
                               now: Time.now.utc)
        event_bytes = event && Hive::Modules::Migration::PatrolEvidence
                               .canonical(event)
        finalized = @occurrence_store.finalize!(
          capture, event_bytes: event_bytes, now: now
        )
        drain_occurrence_outbox!(
          capture.occurrence_id,
          evidence_store: evidence_store,
          event_publisher: event_publisher,
          project_entry: project_entry
        )
        finalized
      end

      # Projection acknowledgement happens only after the observational sink
      # confirms its idempotent append. A failed append leaves the exact
      # canonical bytes pending for the next duplicate/restart.
      def drain_occurrence_outbox!(occurrence_id, evidence_store:,
                                   event_publisher: nil,
                                   project_entry: nil, kinds: nil)
        selected_kinds = kinds && Array(kinds).map(&:to_s)
        @occurrence_store.pending_outbox(occurrence_id).each do |entry|
          next if selected_kinds &&
                  !selected_kinds.include?(entry.fetch("kind"))

          value = JSON.parse(entry.fetch("bytes"))
          case entry.fetch("kind")
          when "receipt"
            evidence_store.append_receipt(
              Hive::Modules::Migration::EffectReceipt.from_h(value)
            )
          when "capture"
            evidence_store.append_capture(
              Hive::Modules::Migration::PatrolCapture.from_h(value)
            )
          when "event"
            unless event_publisher && project_entry
              raise Hive::ConfigError,
                    "patrol finalized event publisher is unavailable"
            end
            event_publisher.publish_prepared(project_entry, value)
          else
            raise Hive::ConfigError, "patrol outbox kind is malformed"
          end
          @occurrence_store.acknowledge_outbox!(
            occurrence_id,
            entry_id: entry.fetch("id"),
            digest: entry.fetch("digest")
          )
        end
        true
      rescue JSON::ParserError
        raise Hive::ConfigError, "patrol outbox bytes are malformed"
      end

      def prepare_effect!(intent, now: Time.now.utc)
        @occurrence_store.prepare_effect!(intent, now: now)
      end

      def effect_state(intent)
        @occurrence_store.effect_state(intent)
      end

      def with_effect_sender_lock(intent, &block)
        @occurrence_store.with_effect_sender_lock(intent, &block)
      end

      def mark_dispatch_uncertain!(intent, now: Time.now.utc)
        @occurrence_store.mark_dispatch_uncertain!(
          intent, now: now
        )
      end

      def reset_effect_prepared!(intent, now: Time.now.utc)
        @occurrence_store.reset_effect_prepared!(
          intent, now: now
        )
      end

      def settle_effect!(intent, status:, outcome:, now: Time.now.utc)
        @occurrence_store.settle_effect!(
          intent, status: status, outcome: outcome, now: now
        )
      end

      def deny_effect!(intent, outcome:, now: Time.now.utc)
        @occurrence_store.deny_effect!(
          intent, outcome: outcome, now: now
        )
      end

      def effect_receipt(receipt_id, occurrence_id:)
        @occurrence_store.receipt(
          receipt_id, occurrence_id: occurrence_id
        )
      end

      def terminal_effect_receipt_ids(occurrence_id)
        @occurrence_store.effect_receipt_ids(occurrence_id)
      end

      def recovery_backoff(now: Time.now.utc)
        @occurrence_store.recovery_backoff(now: now)
      end

      def record_recovery_failure!(operation:, occurrence_id: nil,
                                   job_id: nil, error:,
                                   now: Time.now.utc)
        @occurrence_store.record_recovery_failure!(
          operation: operation,
          occurrence_id: occurrence_id,
          job_id: job_id,
          error: error,
          now: now
        )
      end

      def clear_recovery_failure!(expected_generation:)
        @occurrence_store.clear_recovery_failure!(
          expected_generation: expected_generation
        )
      end

      def write_feature(feature)
        effect_write(
          sink: "state",
          target: "features/#{feature.id}",
          value: feature.to_h
        ) { write_record("features", feature) }
      end

      def write_finding(finding)
        effect_write(
          sink: "finding",
          target: "findings/#{finding.id}",
          value: finding.to_h
        ) { write_record("findings", finding) }
      end

      def findings
        Dir.glob(File.join(root, "findings", "*.json")).sort.filter_map do |path|
          data = read_json(path)
          Finding.from_h(data) unless data.empty?
        rescue KeyError, ArgumentError
          nil
        end
      end

      def transition_finding(finding_or_id, state:, reason:, now: Time.now, superseded_by: nil)
        unless Finding::LIFECYCLE_STATES.include?(state.to_s)
          raise ArgumentError, "unsupported patrol finding lifecycle state #{state.inspect}"
        end

        finding = if finding_or_id.is_a?(Finding)
          finding_or_id
        else
          findings.find { |candidate| candidate.id.to_s == finding_or_id.to_s }
        end
        return unless finding
        return finding if finding.lifecycle_state == state.to_s &&
                          finding.lifecycle_reason == reason.to_s &&
                          finding.superseded_by.to_s == superseded_by.to_s

        finding.lifecycle_state = state.to_s
        finding.lifecycle_reason = reason.to_s
        finding.lifecycle_updated_at = now.utc.iso8601
        finding.superseded_by = superseded_by unless superseded_by.to_s.empty?
        finding.superseded_by = nil unless state.to_s == "superseded"
        write_finding(finding)
      end

      def write_patch(id, data)
        data = data.merge(
          "patrol_occurrence_id" => @effect_capture.occurrence_id
        ) if @effect_capture
        effect_write(
          sink: "state",
          target: "patches/#{id}",
          value: data
        ) { write_json(File.join(root, "patches", "#{id}.json"), data) }
      end

      def patch_record(id)
        identifier = id.to_s
        raise Hive::ConfigError, "patrol patch identity is malformed" unless
          identifier.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)

        value = read_json(
          File.join(root, "patches", "#{identifier}.json")
        )
        unless value["id"].to_s == identifier
          raise Hive::ConfigError, "patrol patch record is unavailable"
        end
        value
      end

      def update_state(data)
        desired = state.merge(data)
        effect_write(
          sink: "state", target: "state", value: desired
        ) { raw_update_state(data) }
      end

      def write_fingerprints(data)
        configured_effect_gateway!
        effect_write(
          sink: "state", target: "fingerprints", value: data
        ) { raw_write_fingerprints(data) }
      end

      def write_dismissed(data)
        effect_write(
          sink: "state", target: "dismissed", value: data
        ) { write_json(File.join(root, "dismissed.json"), data) }
      end

      def write_run_log(id, data)
        effect_write(
          sink: "state", target: "runs/#{id}", value: data
        ) { write_json(File.join(root, "runs", "#{id}.json"), data) }
      end

      def perform_cycle_effect!(sink:, target:, idempotency_key:, capability:,
                                reconcile: nil, &effect)
        raise Hive::ConfigError, "patrol state effect gateway is unavailable" unless @state_effect_gateway

        @state_effect_gateway.perform!(
          sink: sink,
          target: target,
          idempotency_key: idempotency_key,
          capability: capability,
          reconcile: reconcile,
          &effect
        )
      rescue Hive::Patrol::EffectGateway::Denied,
             Hive::Patrol::EffectGateway::ReconciliationRequired => e
        raise Hive::ConfigError, e.message
      end

      def reconcile_attempt(fingerprint)
        return { "status" => "absent", "outcome" => {} } unless @effect_capture

        matches = Dir.glob(File.join(root, "patches", "*.json")).filter_map do |path|
          record = read_json(path)
          next unless record["patrol_occurrence_id"] == @effect_capture.occurrence_id &&
                      record["fingerprint"].to_s == fingerprint.to_s

          record
        end
        return { "status" => "absent", "outcome" => {} } if matches.empty?
        return { "status" => "ambiguous", "outcome" => {} } unless matches.one?

        {
          "status" => "matched",
          "outcome" => { "patch_id" => matches.first.fetch("id") }
        }
      end

      # Publication recovery is an authoritative product mutation, so callers
      # must supply the live effect gateway and an exact reconciliation
      # contract. Gateway admission happens before the fingerprint lock; no
      # gateway-less fallback can regain this write authority.
      def mutate_fingerprints!(
        fingerprint:, idempotency_key:, scope:, set:, deleted:,
        replace: false, capability: "filesystem_write"
      )
        gateway = configured_effect_gateway!
        operation = fingerprint_operation(
          fingerprint, set: set, deleted: deleted, replace: replace
        )
        content_digest = fingerprint_operation_digest(operation)
        recovery_scope = scope.merge(
          "fingerprint_operation" =>
            Hive::Modules::Migration::PatrolEvidence.canonical(operation)
        )
        result = gateway.perform!(
          sink: "state",
          target: "fingerprints/#{fingerprint}",
          idempotency_key: "#{idempotency_key}:#{content_digest}",
          capability: capability,
          scope: recovery_scope,
          reconcile: lambda do |_intent|
            reconcile_fingerprint_mapping(
              fingerprint, set: set, deleted: deleted,
              replace: replace
            )
          end
        ) do
          with_fingerprint_lock do
            data = fingerprints
            apply_fingerprint_operation!(
              data, fingerprint, set: set, deleted: deleted,
              replace: replace
            )
            raw_write_fingerprints(data)
          end
          { "content_digest" => content_digest }
        end
        result
      end

      def reconcile_fingerprint_mapping(fingerprint, set:, deleted:,
                                        replace: false)
        entry = fingerprints[fingerprint.to_s]
        return { "status" => "absent", "outcome" => {} } unless
          entry.is_a?(Hash)

        expected = set.transform_keys(&:to_s)
        matches =
          if replace
            entry == expected
          else
            expected.all? do |key, value|
              entry[key] == value
            end && Array(deleted).all? do |key|
              !entry.key?(key.to_s)
            end
          end
        return {
          "status" => "matched",
          "outcome" => {
            "content_digest" =>
              fingerprint_mapping_digest(
                fingerprint, set: set, deleted: deleted,
                replace: replace
              )
          }
        } if matches

        {
          "status" => "ambiguous",
          "outcome" => {}
        }
      end

      # Runs before any fingerprint read capable of suppressing a finding.
      # Every recovery-active predecessor's exact persisted operations are
      # eligible; competing predecessors for one fingerprint are ambiguous
      # and block.
      def recover_pending_fingerprint_effects!
        configured_effect_gateway!
        intents = []
        each_recovery_active_occurrence do |record|
          capture = Hive::Modules::Migration::PatrolCapture.from_h(
            record.fetch("provisional_capture")
          )
          unless same_effect_project?(capture, @effect_capture)
            raise Hive::ConfigError,
                  "patrol fingerprint recovery project is malformed"
          end
          record.fetch("effects").each do |intent_id, cell|
            next if cell["terminal_receipt_id"]
            next unless %w[prepared dispatch_uncertain].include?(
              cell["state"]
            )

            intent = @occurrence_store.effect_intent(
              capture.occurrence_id, intent_id
            )
            next unless intent.sink == "state" &&
                        intent.target.start_with?("fingerprints/")

            intents << [ intent, capture ]
          end
        end
        duplicate = intents.group_by { |intent, _capture| intent.target }
                           .find do |_target, members|
          members.length > 1
        end
        if duplicate
          raise Hive::ConfigError,
                "multiple nonterminal fingerprint effects share " \
                "#{duplicate.first.inspect}"
        end

        intents.sort_by do |intent, _capture|
          [ intent.target, intent.occurrence_id ]
        end.map do |intent, capture|
          operation = parse_fingerprint_operation(intent)
          fingerprint = operation.fetch("fingerprint")
          set = operation.fetch("set")
          deleted = operation.fetch("deleted")
          replace = operation.fetch("replace")
          digest = fingerprint_mapping_digest(
            fingerprint, set: set, deleted: deleted,
            replace: replace
          )
          effect_gateway_for(capture).recover_intent!(
            intent,
            reconcile: lambda do |_stored_intent|
              reconcile_fingerprint_mapping(
                fingerprint, set: set, deleted: deleted,
                replace: replace
              )
            end
          ) do
            with_fingerprint_lock do
              data = fingerprints
              apply_fingerprint_operation!(
                data, fingerprint, set: set, deleted: deleted,
                replace: replace
              )
              raw_write_fingerprints(data)
            end
            { "content_digest" => digest }
          end
        end
      rescue KeyError, JSON::ParserError, TypeError
        raise Hive::ConfigError,
              "patrol fingerprint recovery operation is malformed"
      end

      private

      def effect_gateway_for(capture)
        options = @effect_gateway_options.merge(
          capture: capture,
          authority: capture.owner
        )
        if @effect_gateway_factory
          @effect_gateway_factory.call(**options)
        else
          Hive::Patrol::EffectGateway.new(**options)
        end
      end

      def same_effect_project?(left, right)
        left.module_name == right.module_name &&
          left.project == right.project
      end

      def fingerprint_mapping_digest(fingerprint, set:, deleted:,
                                     replace: false)
        operation = fingerprint_operation(
          fingerprint, set: set, deleted: deleted, replace: replace
        )
        fingerprint_operation_digest(operation)
      end

      def fingerprint_operation_digest(operation)
        ::Digest::SHA256.hexdigest(
          Hive::Modules::Migration::PatrolEvidence.canonical(operation)
        )
      end

      def fingerprint_operation(fingerprint, set:, deleted:, replace:)
        {
          "deleted" => Array(deleted).map(&:to_s).uniq.sort,
          "fingerprint" => fingerprint.to_s,
          "replace" => replace == true,
          "set" => effect_object(set)
        }.freeze
      end

      def parse_fingerprint_operation(intent)
        encoded = intent.scope.fetch("fingerprint_operation")
        operation = JSON.parse(encoded)
        unless operation.is_a?(Hash) &&
               operation.keys.sort ==
                 %w[deleted fingerprint replace set] &&
               operation["fingerprint"].is_a?(String) &&
               !operation["fingerprint"].empty? &&
               operation["set"].is_a?(Hash) &&
               operation["deleted"].is_a?(Array) &&
               operation["deleted"].all? { |key| key.is_a?(String) } &&
               [ true, false ].include?(operation["replace"]) &&
               intent.target ==
                 "fingerprints/#{operation.fetch('fingerprint')}"
          raise Hive::ConfigError,
                "patrol fingerprint recovery operation is malformed"
        end

        operation
      end

      def apply_fingerprint_operation!(data, fingerprint, set:, deleted:,
                                       replace:)
        key = fingerprint.to_s
        if replace
          data[key] = effect_object(set)
        else
          entry = data[key]
          entry = {} unless entry.is_a?(Hash)
          set.each { |field, value| entry[field.to_s] = value }
          Array(deleted).each { |field| entry.delete(field.to_s) }
          data[key] = entry
        end
        data
      end

      def effect_write(sink:, target:, value:, capability: "filesystem_write")
        return yield unless @state_effect_gateway

        normalized = effect_object(value)
        digest = ::Digest::SHA256.hexdigest(
          Hive::Modules::Migration::PatrolEvidence.canonical(normalized)
        )
        result = @state_effect_gateway.perform!(
          sink: sink,
          target: target,
          idempotency_key: [
            @effect_capture.occurrence_id, sink, target, digest
          ].join(":"),
          capability: capability,
          reconcile: lambda do |_intent|
            observed = effect_target_value(target)
            if observed == normalized
              {
                "status" => "matched",
                "outcome" => { "content_digest" => digest }
              }
            else
              {
                "status" => "absent",
                "outcome" => {
                  "observed" => observed.nil? ? "missing" : "different"
                }
              }
            end
          end
        ) do
          yield
          { "content_digest" => digest }
        end
        normalized
      rescue Hive::Patrol::EffectGateway::Denied,
             Hive::Patrol::EffectGateway::ReconciliationRequired => e
        raise Hive::ConfigError, e.message
      end

      def effect_target_value(target)
        case target
        when "state"
          state
        when "fingerprints"
          fingerprints
        when "dismissed"
          dismissed
        else
          collection, identity = target.split("/", 2)
          return fingerprints[identity] if
            collection == "fingerprints" && identity
          return nil unless identity &&
                            %w[features findings patches runs].include?(collection)

          path = File.join(root, collection, "#{identity}.json")
          File.file?(path) ? read_json(path) : nil
        end
      end

      def raw_update_state(data)
        write_json(File.join(root, "state.json"), state.merge(data))
      end

      def raw_write_fingerprints(data)
        write_json(File.join(root, "fingerprints.json"), data)
      end

      def effect_object(value)
        value = JSON.parse(JSON.generate(value))
        result = Hive::Modules::Migration::PatrolEvidence.immutable_json(
          value, label: "patrol effect recovery state"
        )
        unless result.is_a?(Hash)
          raise Hive::ConfigError, "patrol effect recovery state is malformed"
        end
        result
      rescue JSON::GeneratorError, TypeError
        raise Hive::ConfigError, "patrol effect recovery state is malformed"
      end

      def with_fingerprint_lock(shared: false)
        FileUtils.mkdir_p(root)
        File.open(
          File.join(root, "fingerprints.lock"),
          File::RDWR | File::CREAT,
          0o600
        ) do |lock|
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise Hive::ConfigError,
              "patrol fingerprint lock is unavailable: #{e.message}"
      end
    end
  end
end
