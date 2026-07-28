require "digest"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/base_state_store"
require "hive/patrol/effect_gateway"
require "hive/modules/migration/patrol_evidence"

module Hive
  module Patrol
    class StateStore < BaseStateStore
      def initialize(project_root)
        super(project_root, state_directory: "patrol", collections: %w[features findings patches reports runs])
      end

      # Attach the per-occurrence authorization boundary without changing the
      # incumbent state layout or introducing a recovery store. Cycle effect
      # intent cells live in state.json; PR effect cells continue to live in
      # the fingerprint mapping that already owns publication recovery.
      def configure_effect_gateway!(capture:, evidence_store:, config_loader:,
                                    capability_checker:)
        @effect_capture = capture
        @state_effect_gateway = Hive::Patrol::EffectGateway.new(
          project_root: project_root,
          hive_state_path: File.join(project_root, ".hive-state"),
          capture: capture,
          authority: capture.owner,
          evidence_store: evidence_store,
          intent_writer: method(:reserve_cycle_effect_intent),
          recovery_reader: method(:cycle_effect_intent_state),
          outcome_writer: method(:record_cycle_effect_outcome),
          config_loader: config_loader,
          capability_checker: capability_checker
        )
        self
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

      def update_state(data)
        desired = state.reject { |key, _value| key == "effect_intents" }.merge(data)
        effect_write(
          sink: "state", target: "state", value: desired
        ) { raw_update_state(data) }
      end

      def write_fingerprints(data)
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

        { "status" => "matched", "outcome" => { "patch" => matches.first } }
      end

      # Effect intent/outcome state extends the existing fingerprint mapping;
      # it is not a second recovery ledger. The typed intent is immutable, and
      # every transition rewrites the same keyed cell under one file lock.
      def reserve_effect_intent(fingerprint, intent, context:, now: Time.now.utc)
        intent = effect_intent_value(intent)
        context = effect_object(context)
        disposition = nil
        mutate_fingerprints do |data|
          entry = data[fingerprint.to_s] ||= {
            "first_seen" => now.utc.iso8601
          }
          effects = entry["effect_intents"] ||= {}
          existing = effects[intent.intent_id]
          if existing
            validate_effect_cell!(existing, intent)
            unless existing.fetch("context") == context
              raise Hive::ConfigError,
                    "patrol effect intent context conflicts with existing recovery state"
            end
            disposition = :duplicate
          else
            effects[intent.intent_id] = {
              "intent" => intent.to_h,
              "status" => "intent",
              "outcome" => {},
              "context" => context
            }
            disposition = :created
          end
        end
        disposition
      end

      def effect_intent_state(fingerprint, intent)
        intent = effect_intent_value(intent)
        with_fingerprint_lock(shared: true) do
          data = fingerprints
          cell = data.dig(fingerprint.to_s, "effect_intents", intent.intent_id)
          next nil unless cell

          validate_effect_cell!(cell, intent)
          JSON.parse(JSON.generate(cell))
        end
      end

      def record_effect_outcome(fingerprint, intent, status:, outcome:)
        intent = effect_intent_value(intent)
        status = status.to_s
        allowed = Hive::Modules::Migration::PatrolEvidence::RECEIPT_STATUSES
        unless allowed.include?(status)
          raise Hive::ConfigError, "patrol effect outcome status is malformed"
        end
        outcome = effect_object(outcome)
        mutate_fingerprints do |data|
          cell = data.dig(fingerprint.to_s, "effect_intents", intent.intent_id)
          raise Hive::ConfigError, "patrol effect intent is missing" unless cell

          validate_effect_cell!(cell, intent)
          cell["status"] = status
          cell["outcome"] = outcome
        end
      end

      def mutate_fingerprints
        with_fingerprint_lock do
          data = fingerprints
          yield data
          # Effect cells are the incumbent PR recovery bookkeeping. Writing
          # them must not recursively authorize another state effect while a
          # branch/PR gateway already holds the migration lock.
          raw_write_fingerprints(data)
        end
      end

      private

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
          state.reject { |key, _value| key == "effect_intents" }
        when "fingerprints"
          fingerprints
        when "dismissed"
          dismissed
        else
          collection, identity = target.split("/", 2)
          return nil unless identity &&
                            %w[features findings patches runs].include?(collection)

          path = File.join(root, collection, "#{identity}.json")
          File.file?(path) ? read_json(path) : nil
        end
      end

      def reserve_cycle_effect_intent(intent)
        disposition = nil
        mutate_cycle_effects do |effects|
          existing = effects[intent.intent_id]
          if existing
            validate_cycle_effect_cell!(existing, intent)
            disposition = :duplicate
          else
            effects[intent.intent_id] = {
              "intent" => intent.to_h,
              "status" => "intent",
              "outcome" => {}
            }
            disposition = :created
          end
        end
        disposition
      end

      def cycle_effect_intent_state(intent)
        with_cycle_effect_lock(shared: true) do
          cell = state.dig("effect_intents", intent.intent_id)
          next nil unless cell

          validate_cycle_effect_cell!(cell, intent)
          JSON.parse(JSON.generate(cell))
        end
      end

      def record_cycle_effect_outcome(intent, status:, outcome:)
        status = status.to_s
        allowed = Hive::Modules::Migration::PatrolEvidence::RECEIPT_STATUSES
        unless allowed.include?(status)
          raise Hive::ConfigError, "patrol cycle effect status is malformed"
        end
        outcome = effect_object(outcome)
        mutate_cycle_effects do |effects|
          cell = effects[intent.intent_id]
          raise Hive::ConfigError, "patrol cycle effect intent is missing" unless cell

          validate_cycle_effect_cell!(cell, intent)
          cell["status"] = status
          cell["outcome"] = outcome
        end
      end

      def mutate_cycle_effects
        with_cycle_effect_lock do
          data = state
          effects = data["effect_intents"] ||= {}
          yield effects
          write_json(File.join(root, "state.json"), data)
        end
      end

      def validate_cycle_effect_cell!(cell, intent)
        keys = %w[intent outcome status]
        valid = cell.is_a?(Hash) && cell.keys.sort == keys &&
                cell["intent"] == intent.to_h &&
                ([ "intent" ] +
                 Hive::Modules::Migration::PatrolEvidence::RECEIPT_STATUSES)
                  .include?(cell["status"]) &&
                cell["outcome"].is_a?(Hash)
        raise Hive::ConfigError, "patrol cycle effect recovery state is malformed" unless valid

        true
      end

      def raw_update_state(data)
        write_json(File.join(root, "state.json"), state.merge(data))
      end

      def raw_write_fingerprints(data)
        write_json(File.join(root, "fingerprints.json"), data)
      end

      def effect_intent_value(value)
        return value if value.is_a?(Hive::Modules::Migration::EffectIntent)

        Hive::Modules::Migration::EffectIntent.from_h(value)
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

      def validate_effect_cell!(cell, intent)
        keys = %w[context intent outcome status]
        valid = cell.is_a?(Hash) && cell.keys.sort == keys &&
                cell["intent"] == intent.to_h &&
                ([ "intent" ] +
                 Hive::Modules::Migration::PatrolEvidence::RECEIPT_STATUSES)
                  .include?(cell["status"]) &&
                cell["outcome"].is_a?(Hash) &&
                cell["context"].is_a?(Hash)
        raise Hive::ConfigError, "patrol effect recovery state is malformed" unless valid

        true
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
        raise Hive::ConfigError, "patrol fingerprint lock is unavailable: #{e.message}"
      end

      def with_cycle_effect_lock(shared: false)
        FileUtils.mkdir_p(root)
        File.open(
          File.join(root, "state.lock"),
          File::RDWR | File::CREAT,
          0o600
        ) do |lock|
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise Hive::ConfigError, "patrol state lock is unavailable: #{e.message}"
      end
    end
  end
end
