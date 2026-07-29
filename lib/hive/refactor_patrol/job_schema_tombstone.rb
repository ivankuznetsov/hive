require "json"
require "hive/managed_directory"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Canonical regular-file barrier installed at released `v2/jobs`. A
    # released writer resolves every mutation through that lexical path, so a
    # regular file makes all later child lookups fail while the sealed source
    # directory remains available under its transaction-bound archive name.
    class JobSchemaTombstone
      SCHEMA = "hive-refactor-patrol-job-schema-tombstone".freeze
      SCHEMA_VERSION = 1
      FILE_NAME = "jobs".freeze
      MAX_BYTES = 32 * 1024
      TRANSACTION_ID = /\A(?:native|migration)-[0-9a-f]{32}\z/
      ARCHIVE_NAME = /\A\.job-schema-v3-source-[0-9a-f]{32}\z/
      SNAPSHOT_ID = /\Asnapshot-[0-9a-f]{64}\z/
      ORIGINS = %w[native migrated].freeze
      STATUSES = %w[sealed complete].freeze
      KEYS = %w[
        archive_name origin project_id schema schema_version snapshot_id
        source_schema_version status target_schema_version transaction_id
      ].freeze

      def initialize(directory:, project_id:, target_version:,
                     corrupt_record:, inconsistent_record:)
        @directory = directory
        @project_id = project_id.to_s
        @target_version = Integer(target_version)
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
      end

      def build(origin:, status:, transaction_id:, archive_name: nil,
                snapshot_id: nil)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "project_id" => @project_id,
          "source_schema_version" => 2,
          "target_schema_version" => @target_version,
          "origin" => origin.to_s,
          "status" => status.to_s,
          "transaction_id" => transaction_id.to_s,
          "archive_name" => archive_name,
          "snapshot_id" => snapshot_id
        }
        validate!(payload)
        payload.freeze
      end

      def write(relative = FILE_NAME, **attributes)
        payload = build(**attributes)
        @directory.atomic_write(
          relative, canonical(payload), mode: 0o600
        )
        payload
      end

      def read(relative = FILE_NAME, missing: false)
        bytes = @directory.read(
          relative, max_bytes: MAX_BYTES, missing: missing
        )
        return nil unless bytes

        payload = JSON.parse(bytes)
        corrupt!("tombstone is not canonical", relative) unless
          bytes == canonical(payload)
        validate!(payload)
        payload.freeze
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "tombstone is malformed (#{error.class}: #{error.message})",
          relative
        )
      end

      def assert_complete!(payload, snapshot_id:)
        validate!(payload)
        inconsistent!("JobStore tombstone is not complete") unless
          payload.fetch("status") == "complete"
        expected = snapshot_id
        if payload.fetch("origin") == "native"
          inconsistent!("native JobStore tombstone has a snapshot") unless
            expected.nil? && payload["snapshot_id"].nil?
        elsif payload["snapshot_id"] != expected
          inconsistent!("JobStore tombstone snapshot identity conflicts")
        end
        true
      end

      private

      def validate!(payload)
        valid = payload.is_a?(Hash) &&
          payload.keys.sort == KEYS &&
          payload["schema"] == SCHEMA &&
          payload["schema_version"] == SCHEMA_VERSION &&
          payload["project_id"] == @project_id &&
          payload["source_schema_version"] == 2 &&
          payload["target_schema_version"] == @target_version &&
          ORIGINS.include?(payload["origin"]) &&
          STATUSES.include?(payload["status"]) &&
          payload["transaction_id"].to_s.match?(TRANSACTION_ID)
        corrupt!("tombstone has an invalid shape") unless valid

        if payload.fetch("origin") == "native"
          corrupt!("native tombstone carries migration state") unless
            payload.fetch("status") == "complete" &&
            payload["archive_name"].nil? &&
            payload["snapshot_id"].nil? &&
            payload.fetch("transaction_id").start_with?("native-")
        else
          corrupt!("migrated tombstone identity is malformed") unless
            payload.fetch("transaction_id").start_with?("migration-") &&
            payload["archive_name"].to_s.match?(ARCHIVE_NAME) &&
            (
              payload.fetch("status") == "sealed" &&
                payload["snapshot_id"].nil? ||
              payload.fetch("status") == "complete" &&
                payload["snapshot_id"].to_s.match?(SNAPSHOT_ID)
            )
        end
        payload
      rescue KeyError
        corrupt!("tombstone has an invalid shape")
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def corrupt!(message, relative = FILE_NAME)
        raise @corrupt_record.new(
          message, path: File.join(@directory.root, relative)
        )
      end

      def inconsistent!(message)
        raise @inconsistent_record.new(
          message, path: File.join(@directory.root, FILE_NAME)
        )
      end
    end
  end
end
