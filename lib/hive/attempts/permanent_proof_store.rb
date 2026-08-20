require "json"
require "hive/attempts/point_storage"
require "hive/attempts/record"

module Hive
  module Attempts
    # Immutable, record-compatible schema-v4 proof. It is deliberately
    # point-addressed and exposes no enumeration API.
    class PermanentProofStore
      MAX_RECORD_BYTES = 4 * 1024 * 1024
      MAX_PROJECTION_BINDING_BYTES = 4 * 1024
      KIND = "attempt".freeze
      PROJECTION_BINDING_KIND = "attempt-projection-binding".freeze
      PROJECTION_BINDING_SCHEMA = "hive-attempt-projection-binding".freeze
      PROJECTION_BINDING_SCHEMA_VERSION = 1
      PROJECTION_BINDING_KEYS = %w[
        accepted_at attempt_id intended_stage lease_version outcome
        ownership_generation predecessor_attempt_id state task_id
        task_input_epoch task_slug
      ].freeze

      attr_reader :root

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt permanent proof",
          create_directories: create_directories
        )
        @root = @storage.root
      end

      def fetch(attempt_id)
        id = attempt_id_key(attempt_id)
        bytes = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
        bytes && parse(bytes, expected_attempt_id: id)
      end

      # A task projection binds only attempt identity and lifecycle fields. It
      # does not consume receipts, diagnostics, or inherited output custody.
      # Parsing the immutable proof into a full Record here made every status
      # call revalidate the same growing output arrays across the entire task
      # history. Keep the full #fetch contract unchanged and expose the narrow
      # validated read needed by the projection cache.
      def fetch_projection_binding(attempt_id)
        id = attempt_id_key(attempt_id)
        binding_bytes = @storage.read(
          PROJECTION_BINDING_KIND, key(id), max_bytes: MAX_PROJECTION_BINDING_BYTES
        )
        return parse_projection_binding_document(binding_bytes, expected_attempt_id: id) if binding_bytes

        bytes = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
        bytes && parse_projection_binding(bytes, expected_attempt_id: id)
      end

      def publish(record)
        unless record.is_a?(Record) && record.final?
          raise StoreError, "permanent attempt proof requires a final schema-v4 record"
        end

        id = attempt_id_key(record.attempt_id)
        bytes = JSON.generate(record.to_h) + "\n"
        raise StoreError, "permanent attempt proof is too large" if bytes.bytesize > MAX_RECORD_BYTES

        published = @storage.synchronize(KIND, key(id)) do
          current = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
          if current
            existing = parse(current, expected_attempt_id: id)
            unless existing.to_h == record.to_h
              raise StoreError, "permanent attempt proof conflicts with immutable proof"
            end
            next existing
          end

          @storage.write(
            KIND,
            key(id),
            bytes,
            expected_bytes: nil,
            max_existing_bytes: MAX_RECORD_BYTES
          )
          record
        end
        publish_projection_binding(id, record.to_h)
        published
      end

      def path_for(attempt_id)
        @storage.path_for(KIND, key(attempt_id_key(attempt_id)))
      end

      def projection_binding_path_for(attempt_id)
        @storage.path_for(
          PROJECTION_BINDING_KIND, key(attempt_id_key(attempt_id))
        )
      end

      # Forward-compatible repair for proofs created before compact binding
      # sidecars existed. It validates the binding directly from the immutable
      # full proof and publishes only that subset; full Record consumers remain
      # unchanged.
      def backfill_projection_binding(attempt_id)
        id = attempt_id_key(attempt_id)
        current = @storage.read(
          PROJECTION_BINDING_KIND, key(id), max_bytes: MAX_PROJECTION_BINDING_BYTES
        )
        return parse_projection_binding_document(current, expected_attempt_id: id) if current

        bytes = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
        return nil unless bytes

        binding = parse_projection_binding(bytes, expected_attempt_id: id)
        publish_projection_binding(id, binding)
      end

      private

      def key(attempt_id) = { "attempt_id" => attempt_id }

      def attempt_id_key(value)
        StorageKey.string(value)
      end

      def parse(bytes, expected_attempt_id:)
        raise StoreError, "permanent attempt proof is too large" if bytes.bytesize > MAX_RECORD_BYTES

        record = Record.new(JSON.parse(bytes))
        unless record.attempt_id == expected_attempt_id
          raise StoreError, "permanent attempt proof key collision"
        end
        unless record.final?
          raise StoreError, "permanent attempt proof is not final"
        end

        record
      rescue JSON::ParserError, InvalidRecord => error
        raise StoreError, "permanent attempt proof is unreadable: #{error.message}"
      end

      def parse_projection_binding(bytes, expected_attempt_id:)
        raise InvalidRecord, "permanent attempt proof is too large" if bytes.bytesize > MAX_RECORD_BYTES

        data = JSON.parse(bytes)
        unless data.is_a?(Hash) && data.keys.sort == Record::REQUIRED_KEYS.sort &&
               data["schema"] == Record::SCHEMA && data["schema_version"] == Record::SCHEMA_VERSION
          raise InvalidRecord, "attempt record has invalid schema"
        end
        validate_projection_binding!(data, expected_attempt_id: expected_attempt_id)
        data.slice(*PROJECTION_BINDING_KEYS).freeze
      rescue JSON::ParserError, InvalidRecord => error
        raise StoreError, "permanent attempt proof is unreadable: #{error.message}"
      end

      def parse_projection_binding_document(bytes, expected_attempt_id:)
        if bytes.bytesize > MAX_PROJECTION_BINDING_BYTES
          raise InvalidRecord, "permanent attempt projection binding is too large"
        end

        document = JSON.parse(bytes)
        unless document.is_a?(Hash) && document.keys.sort == %w[binding schema schema_version] &&
               document["schema"] == PROJECTION_BINDING_SCHEMA &&
               document["schema_version"] == PROJECTION_BINDING_SCHEMA_VERSION
          raise InvalidRecord, "attempt projection binding has invalid schema"
        end
        binding = document["binding"]
        unless binding.is_a?(Hash) && binding.keys.sort == PROJECTION_BINDING_KEYS.sort
          raise InvalidRecord, "attempt projection binding has invalid fields"
        end

        validate_projection_binding!(binding, expected_attempt_id: expected_attempt_id)
        binding.freeze
      rescue JSON::ParserError, InvalidRecord => error
        raise StoreError, "permanent attempt projection binding is unreadable: #{error.message}"
      end

      def publish_projection_binding(attempt_id, data)
        binding = data.slice(*PROJECTION_BINDING_KEYS)
        validate_projection_binding!(binding, expected_attempt_id: attempt_id)
        document = {
          "schema" => PROJECTION_BINDING_SCHEMA,
          "schema_version" => PROJECTION_BINDING_SCHEMA_VERSION,
          "binding" => binding
        }
        bytes = JSON.generate(document) + "\n"
        if bytes.bytesize > MAX_PROJECTION_BINDING_BYTES
          raise StoreError, "permanent attempt projection binding is too large"
        end

        @storage.synchronize(PROJECTION_BINDING_KIND, key(attempt_id)) do
          current = @storage.read(
            PROJECTION_BINDING_KIND, key(attempt_id), max_bytes: MAX_PROJECTION_BINDING_BYTES
          )
          if current
            existing = parse_projection_binding_document(
              current, expected_attempt_id: attempt_id
            )
            unless existing == binding
              raise StoreError, "permanent attempt projection binding conflicts with immutable proof"
            end
            next existing
          end

          @storage.write(
            PROJECTION_BINDING_KIND,
            key(attempt_id),
            bytes,
            expected_bytes: nil,
            max_existing_bytes: MAX_PROJECTION_BINDING_BYTES
          )
          binding.freeze
        end
      end

      def validate_projection_binding!(data, expected_attempt_id:)
        unless data["attempt_id"] == expected_attempt_id &&
               Record::FINAL_STATES.include?(data["state"])
          raise InvalidRecord, "permanent attempt proof key or final state is invalid"
        end
        %w[attempt_id task_slug intended_stage ownership_generation accepted_at].each do |name|
          value = data[name]
          unless value.is_a?(String) && !value.empty?
            raise InvalidRecord, "attempt record #{name} must be non-empty"
          end
        end
        unless data["task_input_epoch"].is_a?(Integer) && data["task_input_epoch"] >= 0 &&
               data["lease_version"].is_a?(Integer) && data["lease_version"] >= 0
          raise InvalidRecord, "attempt record projection counters must be non-negative"
        end
        unless data["predecessor_attempt_id"].nil? ||
               data["predecessor_attempt_id"].is_a?(String)
          raise InvalidRecord, "attempt record predecessor identity is invalid"
        end
        unless data["task_id"].nil? || data["task_id"].is_a?(String) ||
               data["task_id"].is_a?(Integer)
          raise InvalidRecord, "attempt record task identity is invalid"
        end
        if data["state"] == "terminal"
          unless Record::TERMINAL_OUTCOMES.include?(data["outcome"])
            raise InvalidRecord, "terminal attempt requires an outcome"
          end
        elsif !data["outcome"].nil?
          raise InvalidRecord, "lost attempt cannot have an outcome"
        end
        Record.parse_time(
          data["accepted_at"], label: "accepted_at", error_class: InvalidRecord
        )
      end
    end
  end
end
