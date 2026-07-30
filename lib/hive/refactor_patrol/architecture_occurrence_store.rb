require "json"
require "hive/modules/migration/occurrence_journal"
require "hive/refactor_patrol/pr_manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Architecture Patrol's product adapter over the shared occurrence journal.
    #
    # The journal remains the sole owner of occurrence/effect state. JobStore
    # owns the immutable occurrence pointer; this adapter validates that
    # architecture effects belong to that aggregate.
    class ArchitectureOccurrenceStore
      MODULE_NAME = "architecture-patrol".freeze

      def initialize(root:, job_reader:, id_validator:, corrupt_record:,
                     inconsistent_record:, journal: nil)
        @job_reader = job_reader
        @id_validator = id_validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @journal = journal || Hive::Modules::Migration::OccurrenceJournal.new(
          File.join(root, "occurrences", "records"),
          module_name: MODULE_NAME
        )
      end

      def reserve_manifest!(manifest, capture:, now: Time.now.utc)
        data = json_copy(manifest)
        Hive::RefactorPatrol::PrManifest.validate!(data)
        capture = capture_value(capture)
        source = data.fetch("source")
        valid = capture.reservation["job_id"] == data.fetch("job_id") &&
                capture.reservation["id"] == data.fetch("job_id") &&
                capture.project["name"] == source.fetch("registration") &&
                capture.project["repository"] == source.fetch("repository") &&
                capture.trigger["manifest_digest"] ==
                  data.fetch("manifest_checksum") &&
                capture.trigger["merge_sha"] == source.fetch("merge_sha")
        raise @inconsistent_record,
              "architecture patrol occurrence does not match its manifest" unless
          valid

        @journal.reserve!(capture, now: now)
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def reserve!(job_id, capture:, now: Time.now.utc)
        id = validate_id!(job_id)
        capture = capture_value(capture)
        aggregate = @job_reader.call(id)
        valid = capture.reservation["job_id"] == id &&
                capture.reservation["id"] == id &&
                capture.project["name"] ==
                  aggregate.dig("source", "registration") &&
                capture.project["repository"] ==
                  aggregate.dig("source", "repository")
        raise @inconsistent_record,
              "architecture patrol occurrence does not match its job" unless valid

        unless aggregate.fetch("occurrence_id") ==
               capture.occurrence_id
          raise @inconsistent_record,
                "architecture patrol job occurrence identity is immutable"
        end

        @journal.reserve!(capture, now: now)
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def fetch_for_job(job_id)
        id = validate_id!(job_id)
        aggregate = @job_reader.call(id)
        occurrence_id = aggregate.fetch("occurrence_id")
        return nil if occurrence_id.to_s.empty?

        @journal.fetch(occurrence_id)
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def capture_for_job(job_id)
        record = fetch_for_job(job_id)
        return nil unless record

        Hive::Modules::Migration::PatrolCapture.from_h(
          record.fetch("provisional_capture")
        )
      end

      def each_recovery_active(&block)
        return @journal.each_recovery_active unless block

        @journal.each_recovery_active(&block)
      end

      def recovery_active? = @journal.recovery_active?

      def rebuild_recovery_index!
        @journal.rebuild_recovery_index!
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def recovery_backoff(now: Time.now.utc)
        @journal.recovery_backoff(now: now)
      end

      def record_recovery_failure!(operation:, occurrence_id: nil,
                                   job_id: nil, error:,
                                   now: Time.now.utc)
        @journal.record_recovery_failure!(
          operation: operation,
          occurrence_id: occurrence_id,
          job_id: job_id,
          error: error,
          now: now
        )
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def clear_recovery_failure!(expected_generation:)
        @journal.clear_recovery_failure!(
          expected_generation: expected_generation
        )
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def prepare_effect!(intent, now: Time.now.utc)
        intent = architecture_intent!(intent)
        assert_effect_scope!(intent)
        @journal.prepare_effect!(intent, now: now)
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def effect_state(intent)
        @journal.effect_state(architecture_intent!(intent))
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def effect_intent(occurrence_id, intent_id)
        @journal.effect_intent(occurrence_id, intent_id)
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def with_effect_sender_lock(intent, &block)
        normalized = architecture_intent!(intent)
        block_error = nil
        @journal.with_effect_sender_lock(normalized) do
          begin
            block.call
          rescue Hive::ConfigError => e
            block_error = e
            raise
          end
        end
      rescue Hive::ConfigError => e
        raise if block_error.equal?(e)

        raise @inconsistent_record, e.message
      end

      def mark_dispatch_uncertain!(intent, now: Time.now.utc)
        @journal.mark_dispatch_uncertain!(
          architecture_intent!(intent), now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def reset_effect_prepared!(intent, now: Time.now.utc)
        @journal.reset_effect_prepared!(
          architecture_intent!(intent), now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def settle_effect!(intent, status:, outcome:, now: Time.now.utc)
        @journal.settle_effect!(
          architecture_intent!(intent),
          status: status, outcome: outcome, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def deny_effect!(intent, outcome:, now: Time.now.utc)
        @journal.deny_effect!(
          architecture_intent!(intent),
          outcome: outcome, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def effect_receipt(receipt_id, occurrence_id:)
        @journal.receipt(receipt_id, occurrence_id: occurrence_id)
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def terminal_effect_receipt_ids(occurrence_id)
        @journal.effect_receipt_ids(occurrence_id)
      rescue Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      def finalize!(capture:, event:, now: Time.now.utc)
        bytes = Hive::WorkflowPackage::CanonicalJSON.generate(event)
        @journal.finalize!(capture, event_bytes: bytes, now: now)
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def drain_outbox!(occurrence_id, evidence_store:, event_publisher: nil,
                        project_entry: nil, kinds: nil)
        selected = kinds && Array(kinds).map(&:to_s)
        @journal.pending_outbox(occurrence_id).each do |entry|
          next if selected && !selected.include?(entry.fetch("kind"))

          publish_outbox_entry!(
            entry,
            evidence_store: evidence_store,
            event_publisher: event_publisher,
            project_entry: project_entry
          )
          @journal.acknowledge_outbox!(
            occurrence_id,
            kind: entry.fetch("kind"),
            entry_id: entry.fetch("id"),
            digest: entry.fetch("digest")
          )
        end
        true
      rescue JSON::ParserError, Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      private

      def architecture_intent!(value)
        intent =
          if value.is_a?(Hive::Modules::Migration::EffectIntent)
            value
          else
            Hive::Modules::Migration::EffectIntent.from_h(value)
          end
        unless intent.module_name == MODULE_NAME
          raise @inconsistent_record,
                "architecture patrol effect intent belongs to another module"
        end
        intent
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def capture_value(value)
        capture =
          if value.is_a?(Hive::Modules::Migration::PatrolCapture)
            value
          else
            Hive::Modules::Migration::PatrolCapture.from_h(value)
          end
        unless capture.module_name == MODULE_NAME
          raise @inconsistent_record,
                "architecture patrol occurrence belongs to another module"
        end
        capture
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def assert_effect_scope!(intent)
        job_id = intent.scope["job_id"].to_s
        if job_id.empty?
          raise @inconsistent_record,
                "architecture patrol effect scope requires job_id"
        end
        occurrence = if intent.sink == "job"
          @journal.fetch(intent.occurrence_id)
        else
          fetch_for_job(job_id)
        end
        unless occurrence &&
               occurrence.fetch("occurrence_id") == intent.occurrence_id &&
               occurrence.dig(
                 "provisional_capture", "reservation", "job_id"
               ) == job_id
          raise @inconsistent_record,
                "architecture patrol effect occurrence does not match its job"
        end
        action_id = intent.scope["canonical_action_id"].to_s
        return true if action_id.empty?

        aggregate = @job_reader.call(job_id)
        return true if aggregate.fetch("actions").any? do |action|
          action.fetch("canonical_action_id") == action_id
        end

        raise @inconsistent_record,
              "architecture patrol effect action does not match its job"
      end

      def publish_outbox_entry!(entry, evidence_store:, event_publisher:,
                                project_entry:)
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
            raise @inconsistent_record,
                  "architecture patrol event publisher is unavailable"
          end
          event_publisher.publish_prepared(project_entry, value)
        else
          raise @corrupt_record,
                "architecture patrol outbox kind is malformed"
        end
      end

      def validate_id!(job_id)
        @id_validator.call(job_id)
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => e
        raise @corrupt_record,
              "refactor patrol job is not JSON serializable (#{e.message})"
      end
    end
  end
end
