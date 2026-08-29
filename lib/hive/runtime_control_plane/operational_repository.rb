require "digest"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # One bounded repository for daemon observations and their complete status
    # generation. The two rows are committed together so readers can never see
    # a cache generation without its scheduler authority.
    class OperationalRepository
      SNAPSHOT_KIND = "operational".freeze
      STATUS_PROJECTION_KEY = "daemon-status-cache".freeze
      STATUS_SOURCE_KIND = "daemon_tick".freeze

      def initialize(database: RuntimeControlPlane.database)
        @database = database
      end

      def publish(snapshot, status_projection: nil)
        snapshot_json = Codec.dump_json(snapshot)
        database.transaction do |db|
          publish_projection(db, status_projection, snapshot, snapshot_json) if status_projection
          installation_id = db[:installations].get(:installation_id)
          raise IntegrityError.new("runtime installation identity is missing", code: :identity_missing) unless
            installation_id

          values = {
            installation_id: installation_id,
            daemon_kind: SNAPSHOT_KIND,
            generation: Integer(snapshot.fetch("tick_sequence")),
            state: daemon_state(snapshot),
            owner_pid: integer_or_nil(snapshot.dig("daemon", "pid")),
            owner_process_identity: snapshot.dig("daemon", "process_start_time")&.to_s,
            observation_json: snapshot_json,
            observed_at: snapshot.fetch("observed_at"),
            expires_at: snapshot["valid_until"]
          }
          db[:daemon_runtime].insert_conflict(
            target: %i[installation_id daemon_kind], update: values
          ).insert(values)
        end
        true
      end

      def snapshot
        database.read do |db|
          row = db[:daemon_runtime].where(daemon_kind: SNAPSHOT_KIND).first
          row && decode_verified(row.fetch(:observation_json))
        end
      end

      def status_projection
        database.read do |db|
          row = db[:projections].where(projection_key: STATUS_PROJECTION_KEY).first
          next nil unless row

          source = db[:daemon_runtime].where(daemon_kind: SNAPSHOT_KIND).first
          raise IntegrityError.new(
            "operational projection source is missing", code: :projection_source_missing
          ) unless source

          snapshot = decode_verified(source.fetch(:observation_json))
          value = decode_verified(row.fetch(:value_json))
          verify_source_binding!(row, source, snapshot, value)

          value
        end
      end

      private

      attr_reader :database

      def publish_projection(db, record, snapshot, snapshot_json)
        verify_projection_pair!(snapshot, record)
        encoded = Codec.dump_json(record)
        values = {
          projection_key: STATUS_PROJECTION_KEY,
          source_kind: STATUS_SOURCE_KIND,
          source_id: snapshot.dig("daemon", "generation").to_s,
          source_generation: Integer(snapshot.fetch("tick_sequence")),
          source_fingerprint: projection_fingerprint(snapshot_json, encoded),
          value_json: encoded,
          created_at: record.fetch("published_at"),
          expires_at: record["valid_until"]
        }
        db[:projections].insert_conflict(target: :projection_key, update: values).insert(values)
      end

      def verify_projection_pair!(snapshot, projection)
        valid = snapshot.fetch("phase") == "complete" &&
          projection.fetch("tick_sequence") == snapshot.fetch("tick_sequence") &&
          projection.fetch("daemon") == snapshot.fetch("daemon")
        return if valid

        raise IntegrityError.new(
          "operational projection does not match its complete daemon generation",
          code: :projection_source_mismatch
        )
      rescue KeyError, TypeError
        raise IntegrityError.new(
          "operational projection source binding is incomplete",
          code: :projection_source_invalid
        )
      end

      def verify_source_binding!(row, source, snapshot, projection)
        valid = row.fetch(:source_kind) == STATUS_SOURCE_KIND &&
          row.fetch(:source_id) == snapshot.dig("daemon", "generation").to_s &&
          Integer(row.fetch(:source_generation)) == Integer(snapshot.fetch("tick_sequence")) &&
          projection.fetch("tick_sequence") == snapshot.fetch("tick_sequence") &&
          projection.fetch("daemon") == snapshot.fetch("daemon") &&
          row.fetch(:source_fingerprint) == projection_fingerprint(
            source.fetch(:observation_json), row.fetch(:value_json)
          )
        return if valid

        raise IntegrityError.new(
          "operational projection source binding does not match the daemon generation",
          code: :projection_source_mismatch
        )
      rescue KeyError, TypeError, ArgumentError
        raise IntegrityError.new(
          "operational projection source binding is invalid",
          code: :projection_source_invalid
        )
      end

      def projection_fingerprint(snapshot_json, projection_json)
        Digest::SHA256.hexdigest("#{snapshot_json}\0#{projection_json}")
      end

      def decode_verified(value)
        Codec.load_json(value)
      rescue CodecError => error
        raise IntegrityError.new(
          "operational projection is invalid: #{error.message}",
          code: :projection_invalid, details: { codec_code: error.code }
        )
      end

      def daemon_state(snapshot)
        return "stopped" if snapshot["shutdown"].is_a?(Hash)

        {
          "started" => "starting",
          "complete" => "running",
          "failed" => "unavailable"
        }.fetch(snapshot.fetch("phase"))
      end

      def integer_or_nil(value)
        value.nil? ? nil : Integer(value)
      end
    end
  end
end
