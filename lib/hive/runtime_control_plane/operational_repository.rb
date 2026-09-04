require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Owns one daemon observation and its optional derived status projection in
    # the same row, so source and cache cannot drift across transactions.
    class OperationalRepository
      def initialize(database: RuntimeControlPlane.database) = @database = database

      def publish(snapshot, status_projection: nil)
        validate_projection!(snapshot, status_projection) if status_projection
        document = { "snapshot" => snapshot, "status_projection" => status_projection }
        @database.transaction do |db|
          installation_id = db[:installations].get(:installation_id) ||
            raise(IntegrityError.new("runtime installation identity is missing", code: :identity_missing))
          values = {
            installation_id: installation_id, observation_json: Codec.dump_json(document)
          }
          db[:daemon_runtime].insert_conflict(
            target: :installation_id, update: values
          ).insert(values)
        end
        true
      end

      def snapshot = read_document&.fetch("snapshot")
      def status_projection
        document = read_document
        projection = document && document["status_projection"]
        validate_projection!(document.fetch("snapshot"), projection) if projection
        projection
      end

      private

      def read_document
        @database.read do |db|
          row = db[:daemon_runtime].first
          row && decode(row.fetch(:observation_json))
        end
      end

      def validate_projection!(snapshot, projection)
        valid = snapshot.fetch("phase") == "complete" &&
          projection.fetch("tick_sequence") == snapshot.fetch("tick_sequence") &&
          projection.fetch("daemon") == snapshot.fetch("daemon")
        raise IntegrityError.new("operational projection source binding differs",
                                 code: :projection_source_mismatch) unless valid
        true
      rescue KeyError, TypeError
        raise IntegrityError.new("operational projection source binding is invalid",
                                 code: :projection_source_invalid)
      end

      def decode(value)
        Codec.load_json(value)
      rescue CodecError => error
        raise IntegrityError.new("operational projection is invalid: #{error.message}",
                                 code: :projection_invalid, details: { codec_code: error.code })
      end
    end
  end
end
