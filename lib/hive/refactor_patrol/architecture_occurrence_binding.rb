require "json"
require "fileutils"
require "hive/atomic_file"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Lock and canonical persistence for the immutable job-to-occurrence
    # binding. It is an identity edge, not an effect/retry state store.
    class ArchitectureOccurrenceBinding
      SCHEMA = "hive-refactor-patrol-job-occurrence".freeze
      SCHEMA_VERSION = 1
      SIZE_LIMIT = 16_384
      OCCURRENCE_ID_PATTERN = /\Aocc-[0-9a-f]{64}\z/

      def initialize(root:, id_validator:, corrupt_record:)
        @root = root
        @id_validator = id_validator
        @corrupt_record = corrupt_record
      end

      def synchronize(job_id)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.open(
          "#{path(job_id)}.lock",
          File::RDWR | File::CREAT,
          0o600
        ) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise @corrupt_record,
              "architecture patrol occurrence lock is unavailable (#{e.message})"
      end

      def fetch(job_id)
        id = validate_id!(job_id)
        record_path = path(id)
        return nil unless File.file?(record_path)

        stat = File.lstat(record_path)
        unless stat.file? && !stat.symlink? && stat.size <= SIZE_LIMIT
          raise @corrupt_record,
                "architecture patrol occurrence index is malformed"
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = File.open(record_path, flags) do |io|
          io.read(SIZE_LIMIT + 1)
        end
        data = JSON.parse(bytes)
        raise @corrupt_record,
              "architecture patrol occurrence index is malformed" unless
          valid?(data, bytes, id)

        data
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError
        raise @corrupt_record,
              "architecture patrol occurrence index is malformed"
      end

      def write(job_id, occurrence_id)
        data = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => validate_id!(job_id),
          "occurrence_id" => occurrence_id
        }
        record_path = path(job_id)
        FileUtils.mkdir_p(File.dirname(record_path), mode: 0o700)
        Hive::AtomicFile.write(
          record_path,
          Hive::WorkflowPackage::CanonicalJSON.generate(data),
          mode: 0o600
        )
        Hive::AtomicFile.fsync_directory(File.dirname(record_path))
        data
      end

      private

      def valid?(data, bytes, job_id)
        bytes == Hive::WorkflowPackage::CanonicalJSON.generate(data) &&
          data.is_a?(Hash) &&
          data.keys.sort ==
            %w[job_id occurrence_id schema schema_version] &&
          data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["job_id"] == job_id &&
          data["occurrence_id"].to_s.match?(OCCURRENCE_ID_PATTERN)
      end

      def directory
        File.join(@root, "occurrences", "jobs")
      end

      def path(job_id)
        File.join(directory, "#{validate_id!(job_id)}.json")
      end

      def validate_id!(job_id)
        @id_validator.call(job_id)
      end
    end
  end
end
