require "json"
require "hive/modules/migration/occurrence_journal"
require "hive/refactor_patrol/architecture_occurrence_binding"
require "hive/refactor_patrol/pr_manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Architecture Patrol's product adapter over the shared occurrence journal.
    #
    # The journal remains the sole owner of occurrence/effect state. This
    # adapter owns only the immutable job-to-occurrence binding and validates
    # that architecture effects belong to the bound JobStore aggregate.
    class ArchitectureOccurrenceStore
      MODULE_NAME = "architecture-patrol".freeze

      def initialize(root:, job_reader:, id_validator:, corrupt_record:,
                     inconsistent_record:, binding: nil, journal: nil)
        @job_reader = job_reader
        @id_validator = id_validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @binding = binding || ArchitectureOccurrenceBinding.new(
          root: root,
          id_validator: id_validator,
          corrupt_record: corrupt_record
        )
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

        reserve_bound!(
          data.fetch("job_id"), capture: capture, now: now
        )
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

        reserve_bound!(id, capture: capture, now: now)
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def fetch_for_job(job_id)
        id = validate_id!(job_id)
        index = @binding.fetch(id)
        return nil unless index

        @journal.fetch(index.fetch("occurrence_id"))
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

      def projection_pending
        @journal.projection_pending
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

      def acquire_effect!(intent, claimant:, now: Time.now.utc, lease_sec: 300)
        @journal.acquire_effect!(
          architecture_intent!(intent), claimant: claimant,
          now: now, lease_sec: lease_sec
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def mark_dispatch_uncertain!(intent, token:, now: Time.now.utc)
        @journal.mark_dispatch_uncertain!(
          architecture_intent!(intent), token: token, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def resolve_effect_absent!(intent, expected_generation:, outcome:,
                                 receipt:, now: Time.now.utc)
        @journal.resolve_absent!(
          architecture_intent!(intent),
          expected_generation: expected_generation,
          outcome: outcome, receipt: receipt, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def settle_effect_reconciled!(intent, expected_generation:, outcome:,
                                    receipt:, now: Time.now.utc)
        @journal.settle_reconciled!(
          architecture_intent!(intent),
          expected_generation: expected_generation,
          outcome: outcome, receipt: receipt, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def settle_effect_claimed!(intent, token:, status:, outcome:, receipt:,
                                 now: Time.now.utc)
        @journal.settle_claimed!(
          architecture_intent!(intent), token: token, status: status,
          outcome: outcome, receipt: receipt, now: now
        )
      rescue Hive::ConfigError => e
        raise @inconsistent_record, e.message
      end

      def deny_effect!(intent, outcome:, receipt:, now: Time.now.utc)
        @journal.deny_prepared!(
          architecture_intent!(intent),
          outcome: outcome, receipt: receipt, now: now
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
            entry_id: entry.fetch("id"),
            digest: entry.fetch("digest")
          )
        end
        true
      rescue JSON::ParserError, Hive::ConfigError => e
        raise @corrupt_record, e.message
      end

      private

      def reserve_bound!(job_id, capture:, now:)
        id = validate_id!(job_id)
        @binding.synchronize(id) do
          existing = @binding.fetch(id)
          if existing &&
             existing.fetch("occurrence_id") != capture.occurrence_id
            raise @inconsistent_record,
                  "architecture patrol job occurrence identity is immutable"
          end
          @journal.reserve!(capture, now: now)
          @binding.write(id, capture.occurrence_id) unless existing
        end
        fetch_for_job(id)
      end

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
        occurrence = fetch_for_job(job_id)
        unless occurrence &&
               occurrence.fetch("occurrence_id") == intent.occurrence_id
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
