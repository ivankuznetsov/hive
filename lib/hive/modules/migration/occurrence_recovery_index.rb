require "json"
require "hive/managed_directory"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Rebuildable, bounded projection of recovery-active occurrence IDs.
      # Occurrence records remain authoritative; this index only prevents an
      # idle daemon tick from rereading the complete retained history.
      class OccurrenceRecoveryIndex
        SCHEMA = "hive-patrol-occurrence-recovery-index".freeze
        SCHEMA_VERSION = 1
        INDEX_NAME = "recovery-index.json".freeze
        MAX_OCCURRENCES = 4_096
        MAX_BYTES = 512 * 1024
        KEYS = %w[
          generation module occurrence_ids schema schema_version
        ].freeze

        def initialize(root:, module_name:, validator:)
          @module_name = module_name.to_s
          @validator = validator
          @directory = Hive::ManagedDirectory.new(
            root: root,
            label: "patrol occurrence recovery index"
          )
        end

        # Missing and structurally malformed projections are repairable. Unsafe
        # filesystem bindings and over-size files remain hard failures.
        def snapshot
          bytes = @directory.read(
            INDEX_NAME, max_bytes: MAX_BYTES, missing: true
          )
          return nil unless bytes

          payload = JSON.parse(bytes)
          return nil unless bytes == canonical(payload)
          return nil unless valid?(payload)

          immutable(payload)
        rescue JSON::ParserError, EncodingError, ArgumentError, TypeError
          nil
        rescue Hive::ManagedDirectory::UnsafeError,
               SystemCallError, IOError => error
          unavailable!(error)
        end

        def write(generation:, occurrence_ids:)
          payload = build(
            generation: generation,
            occurrence_ids: occurrence_ids
          )
          bytes = canonical(payload)
          malformed! if bytes.bytesize > MAX_BYTES
          @directory.atomic_write(
            INDEX_NAME, bytes, mode: 0o600
          )
          immutable(payload)
        rescue Hive::ManagedDirectory::UnsafeError,
               SystemCallError, IOError => error
          unavailable!(error)
        end

        private

        def build(generation:, occurrence_ids:)
          value = Integer(generation)
          malformed! if value.negative?
          ids = Array(occurrence_ids).map do |occurrence_id|
            @validator.occurrence_id(occurrence_id)
          end
          malformed! if ids.size > MAX_OCCURRENCES
          malformed! unless ids.uniq.size == ids.size

          {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "module" => @module_name,
            "generation" => value,
            "occurrence_ids" => ids.sort
          }
        rescue ArgumentError, TypeError
          malformed!
        end

        def valid?(payload)
          return false unless payload.is_a?(Hash) &&
                              payload.keys.sort == KEYS.sort &&
                              payload["schema"] == SCHEMA &&
                              payload["schema_version"] == SCHEMA_VERSION &&
                              payload["module"] == @module_name &&
                              payload["generation"].is_a?(Integer) &&
                              payload["generation"] >= 0

          ids = payload["occurrence_ids"]
          ids.is_a?(Array) &&
            ids.size <= MAX_OCCURRENCES &&
            ids == ids.sort &&
            ids.uniq == ids &&
            ids.all? do |occurrence_id|
              @validator.occurrence_id(occurrence_id)
              true
            rescue Hive::ConfigError
              false
            end
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value).b
        end

        def immutable(value)
          copy = JSON.parse(JSON.generate(value))
          copy.fetch("occurrence_ids").each(&:freeze)
          copy.fetch("occurrence_ids").freeze
          copy.freeze
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol occurrence recovery index is malformed"
        end

        def unavailable!(error)
          raise Hive::ConfigError,
                "patrol occurrence recovery index is unavailable: " \
                "#{error.message}"
        end
      end
    end
  end
end
