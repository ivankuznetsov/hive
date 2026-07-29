require "digest"
require "json"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Canonical, independently checkable evidence that one released v2 job was
    # transformed into the exact v3 checkpoint currently stored in JobStore.
    class JobSchemaConversionProof
      ROOT = "job-schema-v3-conversions".freeze
      SCHEMA = "hive-refactor-patrol-job-schema-conversion".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 32 * 1024
      KEYS = %w[
        intake_transition_id job_id name occurrence_id schema schema_version
        snapshot_id source_digest target_digest
      ].freeze
      SNAPSHOT_ID = /\Asnapshot-[0-9a-f]{64}\z/

      def self.build(snapshot_id:, name:, job_id:, source_digest:,
                     target_bytes:, occurrence_id:, intake_transition_id:)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "snapshot_id" => snapshot_id,
          "name" => name,
          "job_id" => job_id,
          "source_digest" => source_digest,
          "target_digest" => Digest::SHA256.hexdigest(target_bytes),
          "occurrence_id" => occurrence_id,
          "intake_transition_id" => intake_transition_id
        }
      end

      def initialize(transformer:, corrupt_record:, inconsistent_record:)
        @transformer = transformer
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
      end

      def verify!(proof_bytes:, name:, snapshot_id:, source_digest:,
                  source_data:, live_bytes:, path:)
        proof = parse(proof_bytes, path)
        corrupt!("conversion proof is not canonical", path) unless
          proof_bytes == canonical(proof)
        valid = proof.is_a?(Hash) &&
          proof.keys.sort == KEYS &&
          proof["schema"] == SCHEMA &&
          proof["schema_version"] == SCHEMA_VERSION &&
          proof["name"] == name &&
          proof["job_id"] == name.delete_suffix(".json") &&
          proof["snapshot_id"].to_s.match?(SNAPSHOT_ID) &&
          proof["source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
          proof["target_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
          proof["occurrence_id"].to_s.match?(/\Aocc-[0-9a-f]{64}\z/) &&
          proof["intake_transition_id"].to_s
            .match?(/\Aintent-[0-9a-f]{64}\z/)
        corrupt!("conversion proof is malformed", path) unless valid
        unless proof.fetch("snapshot_id") == snapshot_id &&
               proof.fetch("source_digest") == source_digest &&
               proof.fetch("job_id") == source_data.fetch("job_id")
          inconsistent!(
            "conversion proof does not match the selected snapshot",
            path
          )
        end

        expected = @transformer.transform(
          source_data,
          occurrence_id: proof.fetch("occurrence_id"),
          intake_transition_id: proof.fetch("intake_transition_id"),
          path: path
        )
        expected_bytes = "#{JSON.pretty_generate(expected)}\n"
        expected_digest = Digest::SHA256.hexdigest(expected_bytes)
        unless proof.fetch("target_digest") == expected_digest &&
               live_bytes == expected_bytes &&
               Digest::SHA256.hexdigest(live_bytes) == expected_digest
          inconsistent!("v3 job changed after schema migration", path)
        end
        proof
      rescue KeyError => error
        corrupt!(
          "conversion proof is missing #{error.key.inspect}",
          path
        )
      end

      private

      def parse(bytes, path)
        data = JSON.parse(bytes)
        corrupt!("conversion proof must be an object", path) unless
          data.is_a?(Hash)
        data
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "conversion proof is malformed " \
          "(#{error.class}: #{error.message})",
          path
        )
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def corrupt!(message, path)
        raise @corrupt_record.new(message, path: path)
      end

      def inconsistent!(message, path)
        raise @inconsistent_record.new(message, path: path)
      end
    end
  end
end
