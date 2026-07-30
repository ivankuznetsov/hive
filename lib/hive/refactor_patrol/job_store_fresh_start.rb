require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/refactor_patrol/job_store_generation_lock"
require "hive/refactor_patrol/job_store_writer_fence"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # One explicit, opaque retirement of the released v2 JobStore.
    #
    # The exact v2/jobs directory is atomically exchanged with an immutable
    # marker. Its bytes survive under a hidden sibling archive, but this class
    # never enumerates, opens, hashes, validates, or converts them. A separate
    # receipt admits an initially empty v3 namespace after the writer fence.
    class JobStoreFreshStart
      SCHEMA = "hive-refactor-patrol-jobstore-fresh-start".freeze
      SCHEMA_VERSION = 1
      STATUS_SCHEMA =
        "hive-refactor-patrol-jobstore-generation-status".freeze
      STATUS_VERSION = 1
      MARKER_NAME = "jobs".freeze
      RECEIPT_NAME = "jobstore-fresh-start.json".freeze
      MAX_RECORD_BYTES = 32 * 1024
      TRANSACTION_ID = /\Areset-[0-9a-f]{32}\z/
      ARCHIVE_NAME = /\A\.jobs-v2-archive-[0-9a-f]{32}\z/
      MARKER_KEYS = %w[
        archive_name archived_at project_id schema schema_version
        source_generation target_generation target_schema_version
        transaction_id
      ].freeze
      RECEIPT_KEYS = (
        MARKER_KEYS + %w[completed_at marker_digest]
      ).sort.freeze

      def self.archive_name_for(project_id)
        identity = project_id.to_s
        raise ArgumentError, "project_id must be non-empty" if
          identity.empty?

        suffix = Digest::SHA256.hexdigest(
          [ SCHEMA, identity ].join("\0")
        ).slice(0, 32)
        ".jobs-v2-archive-#{suffix}"
      end

      attr_reader :state_root, :target_root

      def initialize(
        state_root:, project:, target_version:, corrupt_record:,
        inconsistent_record:, writer_fence: JobStoreWriterFence.new,
        clock: -> { Time.now.utc }, nonce: nil
      )
        @state_root = File.expand_path(state_root)
        @generation_root = File.join(@state_root, "refactor_patrol")
        @legacy_root = File.join(@generation_root, "v2")
        @target_root = File.join(@generation_root, "v3")
        @project_id = project.fetch("project_id").to_s
        @target_version = Integer(target_version)
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @writer_fence = writer_fence
        @clock = clock
        @nonce = nonce || lambda do
          self.class.archive_name_for(
            @project_id
          ).delete_prefix(".jobs-v2-archive-")
        end
        @generation_directory = managed_directory(
          @generation_root, "refactor patrol JobStore generations"
        )
        @legacy_directory = managed_directory(
          @legacy_root, "released refactor patrol JobStore"
        )
        @target_directory = managed_directory(
          @target_root, "v3 refactor patrol JobStore"
        )
      rescue KeyError, ArgumentError, TypeError => error
        raise ArgumentError,
              "invalid JobStore fresh-start identity (#{error.message})"
      end

      def status
        return status_payload("fresh") unless generation_root_present?

        # Every reset transition below is an atomic name exchange/write whose
        # intermediate state is itself one of the reported statuses. Inspect
        # directly so a read-only status call never creates a lock inode,
        # requires write permission, or waits behind a confirmed reset.
        inspect_status
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        corrupt!(
          "cannot inspect the JobStore generation state " \
          "(#{error.class}: #{error.message})"
        )
      end

      # Normal v3 mutation may initialize a genuinely fresh namespace. It
      # never retires v2 and therefore cannot turn operator intent into a
      # constructor side effect.
      def ensure_current!
        with_lock do
          observed = inspect_status
          case observed.fetch("status")
          when "fresh"
            @target_directory.prepare!
            true
          when "current"
            true
          when "reset_required", "reset_incomplete"
            inconsistent!(
              "explicit fresh-start reset is required before v3 runtime admission"
            )
          else
            inconsistent!(
              "JobStore generation conflict requires operator repair"
            )
          end
        end
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        corrupt!(
          "cannot establish the v3 JobStore namespace " \
          "(#{error.class}: #{error.message})"
        )
      end

      # Explicit operator path. The v2 directory becomes unreachable through
      # its released lexical name before an empty v3 store is admitted.
      def reset!
        with_lock do
          observed = inspect_status
          case observed.fetch("status")
          when "current"
            return observed.merge("changed" => false)
          when "fresh"
            return observed.merge("changed" => false)
          when "conflict"
            inconsistent!(
              "v3 JobStore is not empty; live v2 jobs require operator repair"
            )
          end

          @writer_fence.assert_quiescent!
          marker =
            if observed.fetch("status") == "reset_required"
              assert_empty_target!
              seal_legacy_jobs!
            else
              marker_record
            end
          assert_empty_target!
          @target_directory.prepare!
          write_completion_receipt!(marker)
          completed = inspect_status
          unless completed.fetch("status") == "current"
            inconsistent!(
              "JobStore fresh-start receipt did not admit v3"
            )
          end
          completed.merge("changed" => true)
        end
      rescue @corrupt_record, @inconsistent_record,
             Hive::ConcurrentRunError, Interrupt
        raise
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError,
             TypeError => error
        corrupt!(
          "refactor patrol JobStore fresh-start reset is unsafe " \
          "(#{error.class}: #{error.message})"
        )
      end

      private

      def generation_root_present?
        File.lstat(@generation_root)
        true
      rescue Errno::ENOENT
        false
      end

      def inspect_status
        legacy_kind = @legacy_directory.entry_type(
          MARKER_NAME, missing: true
        )
        target_kind = @generation_directory.entry_type(
          "v3", missing: true
        )
        if target_kind && target_kind != :directory
          corrupt!("v3 JobStore root is not a directory")
        end

        case legacy_kind
        when :directory
          if target_kind && !directory_empty?(@target_directory)
            return status_payload("conflict")
          end
          status_payload("reset_required")
        when :regular
          marker = marker_record
          archive_path = assert_archive!(marker)
          receipt = completion_receipt
          unless receipt
            if target_kind && !directory_empty?(@target_directory)
              return status_payload(
                "conflict", marker: marker, archive_path: archive_path
              )
            end
            return status_payload(
              "reset_incomplete", marker: marker,
              archive_path: archive_path
            )
          end
          validate_receipt_binding!(receipt, marker)
          unless target_kind
            corrupt!(
              "JobStore fresh-start receipt exists without the v3 namespace"
            )
          end
          status_payload(
            "current", marker: marker, archive_path: archive_path
          )
        when nil
          if completion_receipt
            corrupt!(
              "JobStore fresh-start receipt exists without its v2 marker"
            )
          end
          if @legacy_directory.entry_type(
            expected_archive_name, missing: true
          )
            corrupt!(
              "archived v2 JobStore exists without its reset marker"
            )
          end
          status_payload(target_kind ? "current" : "fresh")
        end
      end

      def seal_legacy_jobs!
        archive_name = expected_archive_name
        suffix = archive_name.delete_prefix(".jobs-v2-archive-")
        archive_kind = @legacy_directory.entry_type(
          archive_name, missing: true
        )
        marker =
          case archive_kind
          when nil
            candidate = build_marker(suffix)
            @legacy_directory.atomic_write(
              archive_name, canonical(candidate), mode: 0o600
            )
            persisted = read_record(
              @legacy_directory, archive_name,
              label: "reset marker"
            )
            validate_marker!(persisted)
            persisted
          when :regular
            persisted = read_record(
              @legacy_directory, archive_name,
              label: "reset marker"
            )
            validate_marker!(persisted)
            persisted
          else
            inconsistent!(
              "JobStore reset archive name is already occupied"
            )
          end
        unless marker.fetch("archive_name") == archive_name
          inconsistent!(
            "JobStore reset archive marker identity conflicts"
          )
        end

        @legacy_directory.exchange_directory_with_regular!(
          directory_name: MARKER_NAME,
          regular_name: archive_name
        )
        sealed = marker_record
        unless sealed == marker
          inconsistent!("JobStore reset marker changed during source sealing")
        end
        assert_archive!(sealed)
        sealed
      end

      def expected_archive_name
        suffix = @nonce.call.to_s
        unless suffix.match?(/\A[0-9a-f]{32}\z/)
          raise ArgumentError, "fresh-start nonce is malformed"
        end
        ".jobs-v2-archive-#{suffix}"
      end

      def build_marker(suffix)
        marker = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "project_id" => @project_id,
          "source_generation" => "v2",
          "target_generation" => "v3",
          "target_schema_version" => @target_version,
          "transaction_id" => "reset-#{suffix}",
          "archive_name" => ".jobs-v2-archive-#{suffix}",
          "archived_at" => timestamp(@clock.call)
        }
        validate_marker!(marker)
        marker.freeze
      end

      def marker_record
        marker = read_record(
          @legacy_directory, MARKER_NAME, label: "reset marker"
        )
        validate_marker!(marker)
        marker.freeze
      end

      def completion_receipt
        receipt = read_record(
          @generation_directory, RECEIPT_NAME,
          label: "reset receipt", missing: true
        )
        return nil unless receipt

        validate_receipt!(receipt)
        receipt.freeze
      end

      def write_completion_receipt!(marker)
        receipt = marker.merge(
          "marker_digest" => Digest::SHA256.hexdigest(canonical(marker)),
          "completed_at" => timestamp(@clock.call)
        )
        validate_receipt!(receipt)
        existing = completion_receipt
        if existing
          validate_receipt_binding!(existing, marker)
          return existing
        end
        @generation_directory.atomic_write(
          RECEIPT_NAME, canonical(receipt), mode: 0o600
        )
        persisted = completion_receipt
        unless persisted == receipt
          inconsistent!("JobStore fresh-start receipt changed after write")
        end
        persisted
      end

      def validate_marker!(value)
        valid = value.is_a?(Hash) &&
          value.keys.sort == MARKER_KEYS &&
          value["schema"] == SCHEMA &&
          value["schema_version"] == SCHEMA_VERSION &&
          value["project_id"] == @project_id &&
          value["source_generation"] == "v2" &&
          value["target_generation"] == "v3" &&
          value["target_schema_version"] == @target_version &&
          value["transaction_id"].to_s.match?(TRANSACTION_ID) &&
          value["archive_name"].to_s.match?(ARCHIVE_NAME)
        corrupt!("reset marker has an invalid shape") unless valid
        timestamp(value.fetch("archived_at"))
        suffix = value.fetch("transaction_id").delete_prefix("reset-")
        unless value.fetch("archive_name") == ".jobs-v2-archive-#{suffix}"
          corrupt!("reset marker archive identity conflicts")
        end
        value
      end

      def validate_receipt!(value)
        valid = value.is_a?(Hash) &&
          value.keys.sort == RECEIPT_KEYS &&
          value["marker_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
        corrupt!("reset receipt has an invalid shape") unless valid
        validate_marker!(
          value.reject { |key, _item|
            %w[completed_at marker_digest].include?(key)
          }
        )
        timestamp(value.fetch("completed_at"))
        value
      end

      def validate_receipt_binding!(receipt, marker)
        marker_digest = Digest::SHA256.hexdigest(canonical(marker))
        marker_fields = receipt.reject { |key, _item|
          %w[completed_at marker_digest].include?(key)
        }
        unless marker_fields == marker &&
               receipt.fetch("marker_digest") == marker_digest
          inconsistent!("JobStore fresh-start receipt conflicts with marker")
        end
        true
      end

      def assert_archive!(marker)
        archive_name = marker.fetch("archive_name")
        unless @legacy_directory.entry_type(
          archive_name, missing: true
        ) == :directory
          corrupt!("archived v2 JobStore directory is unavailable")
        end
        File.join(@legacy_root, archive_name)
      end

      def assert_empty_target!
        kind = @generation_directory.entry_type("v3", missing: true)
        return true unless kind
        corrupt!("v3 JobStore root is not a directory") unless
          kind == :directory
        return true if directory_empty?(@target_directory)

        inconsistent!(
          "v3 JobStore is not empty; refusing to overwrite current state"
        )
      end

      def directory_empty?(directory)
        directory.each_child.first.nil?
      end

      def read_record(directory, relative, label:, missing: false)
        bytes = directory.read(
          relative, max_bytes: MAX_RECORD_BYTES, missing: missing
        )
        return nil unless bytes

        value = JSON.parse(bytes)
        corrupt!("#{label} is not canonical") unless
          bytes == canonical(value)
        value
      rescue JSON::ParserError, EncodingError => error
        corrupt!(
          "#{label} is malformed (#{error.class}: #{error.message})"
        )
      end

      def status_payload(status, marker: nil, archive_path: nil)
        {
          "schema" => STATUS_SCHEMA,
          "schema_version" => STATUS_VERSION,
          "status" => status,
          "project_id" => @project_id,
          "source_generation" => "v2",
          "target_generation" => "v3",
          "target_schema_version" => @target_version,
          "transaction_id" => marker && marker.fetch("transaction_id"),
          "archive_path" => archive_path,
          "receipt_path" =>
            marker ? File.join(@generation_root, RECEIPT_NAME) : nil
        }
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        canonical = time.utc.iso8601
        unless value.is_a?(Time) || value.to_s == canonical
          raise ArgumentError, "timestamp is not canonical UTC"
        end
        canonical
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def managed_directory(root, label)
        Hive::ManagedDirectory.new(
          root: root, label: label
        )
      end

      def with_lock(&block)
        JobStoreGenerationLock.with_lock(@state_root, &block)
      end

      def corrupt!(message)
        raise @corrupt_record.new(message, path: @generation_root)
      end

      def inconsistent!(message)
        raise @inconsistent_record.new(message, path: @generation_root)
      end
    end
  end
end
