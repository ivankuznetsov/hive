require "json"
require "hive/managed_directory"

module Hive
  module RefactorPatrol
    # Descriptor-confined physical storage for the v3 JobStore. Domain
    # validation remains in JobStore; this collaborator owns every mutable
    # file lookup so a namespace symlink swap cannot redirect a later read,
    # lock, or write outside the registered Hive state root.
    class JobStoreFiles
      MAX_JOB_BYTES = 8 * 1024 * 1024
      MAX_JSON_BYTES = 64 * 1024 * 1024
      MAX_JOB_ENTRIES = 8_192
      MAX_JOB_FILES = MAX_JOB_ENTRIES * 2
      JOB_ID_SOURCE = "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}".freeze
      JOB_ID = /\A#{JOB_ID_SOURCE}\z/
      JOB_JSON = /\A(#{JOB_ID_SOURCE})\.json\z/
      JOB_LOCK = /\A#{JOB_ID_SOURCE}\.json\.lock\z/

      attr_reader :directory, :root

      def initialize(root:, anchor:, corrupt_record:, inconsistent_record:,
                     directory: nil)
        @root = File.expand_path(root)
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @directory = directory || Hive::ManagedDirectory.new(
          root: @root,
          anchor: File.expand_path(anchor),
          label: "v3 refactor patrol JobStore"
        )
      end

      def prepare!
        directory.prepare!
      end

      def relative_path(path)
        directory.relative_path(path)
      end

      def absolute_path(relative)
        File.join(root, relative)
      end

      def job_path(job_id)
        absolute_path(job_relative(job_id))
      end

      def job_exists?(job_id)
        regular?(job_relative(job_id))
      end

      def with_job_lock(job_id, &block)
        id = validated_job_id(job_id)
        directory.with_lock(
          File.join("jobs", "#{id}.json.lock"),
          &block
        )
      end

      # New authoritative jobs are admitted under one store-wide capacity
      # lock before their persistent per-job lock is created. Existing jobs
      # remain writable at capacity, while concurrent creators cannot both
      # observe the last free slot.
      def with_job_admission(job_id)
        id = validated_job_id(job_id)
        directory.with_lock("jobs-admission.lock") do
          unless job_exists?(id)
            count = 0
            each_job_id { count += 1 }
            if count >= MAX_JOB_ENTRIES
              inconsistent!(
                "refactor patrol JobStore capacity is exhausted",
                "jobs"
              )
            end
          end
          with_job_lock(id) { yield }
        end
      end

      def with_action_catalog_lock(&block)
        directory.with_lock("actions.lock", &block)
      end

      def read_job(job_id)
        directory.read(
          job_relative(job_id),
          max_bytes: MAX_JOB_BYTES
        )
      end

      def write_job(job_id, bytes)
        directory.atomic_write(
          job_relative(job_id),
          bytes,
          mode: 0o600
        )
      end

      def each_job_id
        return enum_for(__method__) unless block_given?

        names = []
        directory.each_child("jobs", missing: true) do |name|
          names << name
          corrupt!("refactor patrol job inventory is too large", "jobs") if
            names.size > MAX_JOB_FILES
        end
        ids = names.filter_map do |name|
          match = JOB_JSON.match(name)
          next match[1] if match
          next if name.match?(JOB_LOCK)

          corrupt!(
            "refactor patrol job inventory contains an unknown entry",
            File.join("jobs", name)
          )
        end
        corrupt!("refactor patrol job inventory has too many jobs", "jobs") if
          ids.size > MAX_JOB_ENTRIES
        ids.sort.each do |job_id|
          unless regular?(job_relative(job_id))
            corrupt!(
              "refactor patrol job is not a regular file",
              job_relative(job_id)
            )
          end
          yield job_id
        end
        nil
      end

      def read_json(relative, max_bytes: MAX_JSON_BYTES, missing: false)
        bytes = directory.read(
          relative,
          max_bytes: max_bytes,
          missing: missing
        )
        return nil unless bytes

        JSON.parse(bytes)
      end

      def write_json(relative, value)
        directory.atomic_write(
          relative,
          "#{JSON.pretty_generate(value)}\n",
          mode: 0o600
        )
      end

      def regular?(relative)
        type = directory.entry_type(relative, missing: true)
        return false unless type
        return true if type == :regular

        corrupt!(
          "refactor patrol JobStore entry is not a regular file",
          relative
        )
      end

      private

      def job_relative(job_id)
        File.join("jobs", "#{validated_job_id(job_id)}.json")
      end

      def validated_job_id(job_id)
        id = job_id.to_s
        inconsistent!(
          "refactor patrol JobStore job id is invalid",
          "jobs"
        ) unless id.match?(JOB_ID)
        id
      end

      def corrupt!(message, relative)
        raise @corrupt_record.new(
          message,
          path: absolute_path(relative)
        )
      end

      def inconsistent!(message, relative)
        raise @inconsistent_record.new(
          message,
          path: absolute_path(relative)
        )
      end
    end
  end
end
