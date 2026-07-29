require "digest"
require "json"
require "time"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # One immutable, exact-byte backup of the released JobStore v2 aggregates.
    # The fixed snapshot is completed before the first live record is replaced,
    # so an interrupted migration either has no manifest or has a complete,
    # independently verifiable rollback source.
    class JobSchemaSnapshot
      SCHEMA = "hive-refactor-patrol-job-schema-snapshot".freeze
      SCHEMA_VERSION = 1
      ROOT = "job-schema-v2-backup".freeze
      MANIFEST = File.join(ROOT, "manifest.json").freeze
      MAX_MANIFEST_BYTES = 2 * 1024 * 1024
      MAX_JOB_ENTRIES = 8_192
      MAX_JOB_BYTES = 8 * 1024 * 1024
      KEYS = %w[
        created_at entries project_id schema schema_version snapshot_id
        source_schema_version
      ].freeze
      ENTRY_KEYS = %w[bytes digest mode mtime name].freeze

      attr_reader :snapshot_id

      def initialize(directory:, project_id:, corrupt_record:,
                     inconsistent_record:, clock: -> { Time.now.utc })
        @directory = directory
        @project_id = project_id.to_s
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @clock = clock
      end

      # entries is the single migration inventory's v2 subset. Each value must
      # contain :bytes, :digest, :mode, and :mtime captured before mutation.
      def prepare!(entries, current_names: nil)
        current_names ||= entries.map { |entry| entry.fetch(:name) }
        existing = read_manifest
        if existing
          verify_manifest!(existing)
          assert_source_covered!(
            existing, entries, current_names: current_names
          )
          @snapshot_id = existing.fetch("snapshot_id")
          return existing
        end

        normalized = entries.sort_by { |entry| entry.fetch(:name) }.map do |entry|
          {
            "name" => entry.fetch(:name),
            "digest" => entry.fetch(:digest),
            "bytes" => entry.fetch(:bytes).bytesize,
            "mode" => Integer(entry.fetch(:mode)),
            "mtime" => entry.fetch(:mtime).to_s
          }
        end
        assert_exact_names!(
          normalized.map { |entry| entry.fetch("name") },
          current_names
        )
        entries.each { |entry| write_backup!(entry) }
        identity = {
          "project_id" => @project_id,
          "source_schema_version" => 2,
          "entries" => normalized
        }
        @snapshot_id =
          "snapshot-#{Digest::SHA256.hexdigest(canonical(identity))}"
        manifest = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "snapshot_id" => @snapshot_id,
          "project_id" => @project_id,
          "source_schema_version" => 2,
          "created_at" => timestamp(@clock.call),
          "entries" => normalized
        }
        @directory.atomic_write(
          MANIFEST, canonical(manifest), mode: 0o600
        )
        verify_manifest!(read_manifest)
      end

      def manifest
        value = read_manifest
        verify_manifest!(value) if value
        value
      end

      def backup_bytes(entry)
        bytes = @directory.read(
          File.join(ROOT, "jobs", entry.fetch("name")),
          max_bytes: MAX_JOB_BYTES
        )
        unless bytes.bytesize == entry.fetch("bytes") &&
               Digest::SHA256.hexdigest(bytes) == entry.fetch("digest")
          inconsistent!(
            "snapshot backup digest does not match its manifest",
            entry.fetch("name")
          )
        end
        bytes
      end

      private

      def write_backup!(entry)
        name = entry.fetch(:name)
        bytes = entry.fetch(:bytes)
        digest = entry.fetch(:digest)
        unless Digest::SHA256.hexdigest(bytes) == digest
          inconsistent!("snapshot source digest changed", name)
        end
        relative = File.join(ROOT, "jobs", name)
        current = @directory.read(
          relative, max_bytes: MAX_JOB_BYTES, missing: true
        )
        if current
          unless Digest::SHA256.hexdigest(current) == digest &&
                 current == bytes
            inconsistent!("snapshot backup conflicts", relative)
          end
          return
        end
        @directory.atomic_write(
          relative,
          bytes,
          mode: Integer(entry.fetch(:mode)) & 0o777
        )
      end

      def read_manifest
        bytes = @directory.read(
          MANIFEST, max_bytes: MAX_MANIFEST_BYTES, missing: true
        )
        return nil unless bytes

        data = JSON.parse(bytes)
        corrupt!("snapshot manifest is not canonical", MANIFEST) unless
          bytes == canonical(data)
        data
      rescue JSON::ParserError, EncodingError, ArgumentError => error
        corrupt!(
          "snapshot manifest is malformed " \
          "(#{error.class}: #{error.message})",
          MANIFEST
        )
      end

      def verify_manifest!(manifest)
        corrupt!("snapshot manifest is missing", MANIFEST) unless
          manifest.is_a?(Hash)
        corrupt!("snapshot manifest has an invalid shape", MANIFEST) unless
          manifest.keys.sort == KEYS &&
          manifest["schema"] == SCHEMA &&
          manifest["schema_version"] == SCHEMA_VERSION &&
          valid_created_at?(manifest["created_at"]) &&
          manifest["source_schema_version"] == 2 &&
          manifest["project_id"] == @project_id &&
          manifest["snapshot_id"].to_s.match?(/\Asnapshot-[0-9a-f]{64}\z/) &&
          manifest["entries"].is_a?(Array) &&
          manifest["entries"].size.between?(1, MAX_JOB_ENTRIES)
        entries = manifest.fetch("entries")
        names = entries.map do |entry|
          corrupt!("snapshot entry has an invalid shape", MANIFEST) unless
            entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS &&
            entry["name"].to_s.match?(
              /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\.json\z/
            ) &&
            entry["digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
            entry["bytes"].is_a?(Integer) &&
            entry["bytes"].between?(1, MAX_JOB_BYTES) &&
            entry["mode"].is_a?(Integer) &&
            entry["mode"].between?(0, 0o777) &&
            valid_mtime?(entry["mtime"])
          bytes = @directory.read(
            File.join(ROOT, "jobs", entry.fetch("name")),
            max_bytes: MAX_JOB_BYTES
          )
          inconsistent!(
            "snapshot backup digest does not match its manifest",
            entry.fetch("name")
          ) unless bytes.bytesize == entry.fetch("bytes") &&
                   Digest::SHA256.hexdigest(bytes) == entry.fetch("digest")
          entry.fetch("name")
        end
        inconsistent!("snapshot contains duplicate job names", MANIFEST) unless
          names == names.uniq.sort
        identity = {
          "project_id" => manifest.fetch("project_id"),
          "source_schema_version" =>
            manifest.fetch("source_schema_version"),
          "entries" => entries
        }
        expected =
          "snapshot-#{Digest::SHA256.hexdigest(canonical(identity))}"
        inconsistent!("snapshot identity does not match its contents", MANIFEST) unless
          manifest.fetch("snapshot_id") == expected
        @snapshot_id = expected
        manifest
      end

      def assert_source_covered!(manifest, entries, current_names:)
        expected = manifest.fetch("entries").to_h do |entry|
          [ entry.fetch("name"), entry.fetch("digest") ]
        end
        assert_exact_names!(expected.keys, current_names)
        entries.each do |entry|
          unless expected[entry.fetch(:name)] == entry.fetch(:digest)
            inconsistent!(
              "a released v2 job was introduced after the snapshot",
              entry.fetch(:name)
            )
          end
        end
      end

      def assert_exact_names!(expected, current)
        return if current.map(&:to_s).sort == expected.sort

        inconsistent!(
          "live JobStore does not have the snapshot's exact job name set",
          MANIFEST
        )
      end

      def valid_mtime?(value)
        text = value.to_s
        !text.empty? &&
          Time.iso8601(text).utc.iso8601(9) == text
      rescue ArgumentError, TypeError
        false
      end

      def valid_created_at?(value)
        text = value.to_s
        !text.empty? &&
          Time.iso8601(text).utc.iso8601(6) == text
      rescue ArgumentError, TypeError
        false
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        corrupt!("snapshot time is malformed", MANIFEST)
      end

      def corrupt!(message, relative)
        raise @corrupt_record.new(
          message,
          path: File.join(@directory.root, relative)
        )
      end

      def inconsistent!(message, relative)
        raise @inconsistent_record.new(
          message,
          path: File.join(@directory.root, relative)
        )
      end
    end
  end
end
