require "digest"
require "json"
require "fileutils"
require "hive/atomic_file"
require "hive/attempts/capability"
require "hive/attempts/record"
require "hive/stringify_keys"
require "hive/paths"

module Hive
  module Attempts
    class StoreError < Hive::Error; end
    class CompareAndSwapFailed < StoreError; end

    # Invalid records are deliberately retained by scans and count as a
    # reservation. A downgraded or partially written store must never create
    # capacity for a duplicate owner by ignoring evidence it cannot parse.
    InvalidStoredRecord = Data.define(:path, :error) do
      def capacity_reservation? = true
    end
    Scan = Data.define(:records, :invalid_records)

    class Store
      def initialize(root: Hive::Paths.attempts_root, create_directories: true)
        @root = File.expand_path(root)
        @create_directories = create_directories
        reject_legacy_default_store!
        @records_root = File.join(@root, "records")
        @logs_root = File.join(@root, "logs")
        @outputs_root = File.join(@root, "outputs")
        @generation_locks_root = File.join(@root, "generation-locks")
        ensure_private_directories! if create_directories
      end

      def root
        managed_directory_path(@root, label: "root")
      end

      def records_root
        managed_directory_path(@records_root, label: "records")
      end

      def logs_root
        managed_directory_path(@logs_root, label: "logs")
      end

      def outputs_root
        managed_directory_path(@outputs_root, label: "outputs")
      end

      def generation_locks_root
        managed_directory_path(@generation_locks_root, label: "generation-locks")
      end

      def output_directory(attempt_id, *segments, create: false)
        components = [ attempt_id, *segments ].map { |segment| safe_id(segment) }
        path = outputs_root
        missing_parent = false
        components.each do |component|
          path = File.join(path, component)
          next if missing_parent

          begin
            status = File.lstat(path)
          rescue Errno::ENOENT
            unless create
              missing_parent = true
              next
            end

            begin
              Dir.mkdir(path, 0o700)
            rescue Errno::EEXIST
              # Another legitimate worker may create the same per-attempt
              # directory after our lstat. Re-observe below and accept only
              # the exact real-directory shape we would have created.
            end
            status = File.lstat(path)
          end
          if status.symlink?
            raise StoreError, "attempt output directory #{component} is a symlink"
          end
          unless status.directory?
            raise StoreError, "attempt output path #{component} is not a directory"
          end

          validate_output_custody!(path)
          File.chmod(0o700, path) if create
        end
        path
      rescue SystemCallError => e
        raise StoreError, "attempt output directory is unavailable: #{e.message}"
      end

      def output_path(attempt_id, filename, create_directory: false)
        path = File.join(
          output_directory(attempt_id, create: create_directory),
          safe_id(filename)
        )
        if (status = optional_lstat(path))
          raise StoreError, "attempt output file is a symlink" if status.symlink?
          raise StoreError, "attempt output path is not a regular file" unless status.file?
        end

        path
      end

      def create_launching(**attributes)
        record = Record.launching(**attributes)
        with_record_lock(record.attempt_id) do
          persist(record, expected_absent: true)
        end
        record
      end

      def fetch(attempt_id)
        path = record_path(attempt_id)
        validate_regular_file!(path, label: "attempt record")
        Record.new(JSON.parse(File.binread(path)))
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, InvalidRecord => e
        raise StoreError, "attempt #{attempt_id} is unreadable: #{e.message}"
      end

      def scan
        records = []
        invalid = []
        Dir.glob(File.join(records_root, "*.json")).sort.each do |path|
          begin
            validate_regular_file!(path, label: "attempt record")
            records << Record.new(JSON.parse(File.binread(path)))
          rescue JSON::ParserError, InvalidRecord, StoreError, SystemCallError => e
            invalid << InvalidStoredRecord.new(path: path, error: e.message)
          end
        end
        Scan.new(records: records.freeze, invalid_records: invalid.freeze)
      end

      def for_generation(task_generation)
        scan.records.select { |record| record.task_generation == task_generation }
      end

      def claim(observed, owner:, claim_capability:, first_heartbeat_timeout_sec:, now:)
        raise CompareAndSwapFailed, "launch claim deadline expired" if observed.active_deadline && now > observed.active_deadline
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          unless Capability.matches?(data["claim_capability_digest"], claim_capability)
            raise CompareAndSwapFailed, "attempt claim capability is invalid"
          end
          raise CompareAndSwapFailed, "attempt is already claimed" if data["wrapper"]

          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "wrapper" => Hive::StringifyKeys.call(owner),
            "claim_deadline" => nil,
            "first_heartbeat_deadline" => Record.iso8601(now + first_heartbeat_timeout_sec),
            "diagnostics" => data.fetch("diagnostics").merge("claimed_at" => Record.iso8601(now))
          )
        end
      end

      def first_heartbeat(observed, stale_sec:, now:)
        raise CompareAndSwapFailed, "first heartbeat deadline expired" if observed.active_deadline && now > observed.active_deadline
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          raise CompareAndSwapFailed, "attempt has not been claimed" unless data["wrapper"]

          timestamp = Record.iso8601(now)
          data.merge(
            "state" => "running",
            "lease_version" => data.fetch("lease_version") + 1,
            "first_heartbeat_deadline" => nil,
            "heartbeat_at" => timestamp,
            "heartbeat_deadline" => Record.iso8601(now + stale_sec),
            "started_at" => timestamp
          )
        end
      end

      def heartbeat(observed, stale_sec:, now:)
        mutate(observed, allowed_states: [ "running" ]) do |data|
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "heartbeat_at" => Record.iso8601(now),
            "heartbeat_deadline" => Record.iso8601(now + stale_sec)
          )
        end
      end

      def checkpoint(observed, checkpoint:, now:, worker: nil, output_references: nil, log_reference: nil)
        mutate(observed, allowed_states: [ "running" ]) do |data|
          next_outputs = output_references.nil? ? data.fetch("current_outputs") : Hive::StringifyKeys.call(output_references)
          next_outputs.each { |reference| OutputReference.validate_shape!(reference) }
          OutputReference.validate_shape!(log_reference) if log_reference
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "checkpoint" => Hive::StringifyKeys.call(checkpoint),
            "latest_revision" => checkpoint["revision"] || checkpoint[:revision] || data["latest_revision"],
            "worker" => worker ? Hive::StringifyKeys.call(worker) : data["worker"],
            "current_outputs" => next_outputs,
            "log_reference" => log_reference || data["log_reference"],
            "diagnostics" => data.fetch("diagnostics").merge("checkpoint_at" => Record.iso8601(now))
          )
        end
      end

      def terminalize(observed, outcome:, exit_status:, final_checkpoint:, output_references:,
                      log_reference:, now:)
        receipt = {
          "attempt_id" => observed.attempt_id,
          "task_generation" => observed.task_generation,
          "ownership_generation" => observed.ownership_generation,
          "task_input_epoch" => observed.task_input_epoch,
          "outcome" => outcome,
          "exit_status" => exit_status,
          "started_at" => observed["started_at"],
          "ended_at" => Record.iso8601(now),
          "final_checkpoint" => Hive::StringifyKeys.call(final_checkpoint),
          "output_references" => Hive::StringifyKeys.call(output_references),
          "log_reference" => Hive::StringifyKeys.call(log_reference)
        }
        Record.validate_receipt!(
          receipt, attempt_id: observed.attempt_id,
          task_generation: observed.task_generation,
          ownership_generation: observed.ownership_generation,
          task_input_epoch: observed.task_input_epoch
        )
        mutate(observed, allowed_states: [ "running" ]) do |data|
          data.merge(
            "state" => "terminal",
            "outcome" => outcome,
            "lease_version" => data.fetch("lease_version") + 1,
            "heartbeat_deadline" => nil,
            "ended_at" => Record.iso8601(now),
            "latest_revision" => final_checkpoint["revision"] || final_checkpoint[:revision] || data["latest_revision"],
            "checkpoint" => Hive::StringifyKeys.call(final_checkpoint),
            "current_outputs" => Hive::StringifyKeys.call(output_references),
            "log_reference" => Hive::StringifyKeys.call(log_reference),
            "receipt" => receipt
          )
        end
      end

      def mark_lost(observed, reason:, now:, diagnostics: {})
        mutate(observed, allowed_states: %w[launching running]) do |data|
          data.merge(
            "state" => "lost",
            "lease_version" => data.fetch("lease_version") + 1,
            "claim_deadline" => nil,
            "first_heartbeat_deadline" => nil,
            "heartbeat_deadline" => nil,
            "ended_at" => Record.iso8601(now),
            "loss" => { "reason" => reason, "at" => Record.iso8601(now) },
            "diagnostics" => data.fetch("diagnostics").merge(Hive::StringifyKeys.call(diagnostics))
          )
        end
      end

      # Enrich an already-lost record after orphan cleanup / dirty capture.
      # The irreversible state and immutable identity remain unchanged.
      def annotate_lost(observed, output_references:, diagnostics:, now:)
        mutate(observed, allowed_states: [ "lost" ]) do |data|
          outputs = (data.fetch("current_outputs") + Hive::StringifyKeys.call(output_references)).uniq
          outputs.each { |reference| OutputReference.validate_shape!(reference) }
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "current_outputs" => outputs,
            "diagnostics" => data.fetch("diagnostics").merge(
              Hive::StringifyKeys.call(diagnostics).merge("loss_processed_at" => Record.iso8601(now))
            )
          )
        end
      end

      def with_generation_lock(task_generation)
        path = generation_lock_path(task_generation)
        open_lock(path) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise StoreError, "attempt generation lock is unavailable: #{e.message}"
      end

      # Serializes the global capacity snapshot/create decision across every
      # generation. Callers that also need a generation lock must always take
      # this admission lock first so distinct task generations cannot each
      # observe the same final capacity slot.
      def with_admission_lock
        path = File.join(generation_locks_root, "admission.lock")
        open_lock(path) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise StoreError, "attempt admission lock is unavailable: #{e.message}"
      end

      def record_path(attempt_id)
        File.join(records_root, "#{safe_id(attempt_id)}.json")
      end

      def generation_lock_path(task_generation)
        digest = ::Digest::SHA256.hexdigest(task_generation.to_s)
        File.join(generation_locks_root, "#{digest}.lock")
      end

      private

      def reject_legacy_default_store!
        return unless @root == File.expand_path(Hive::Paths.attempts_root)
        legacy_root = File.join(Hive::Paths.state_home, "attempts", "v1")
        return unless File.exist?(legacy_root)

        raise StoreError,
              "legacy attempt state remains at #{legacy_root}; run `hive migrate` " \
              "or restart the current Hive daemon before opening attempts/v2"
      end

      def mutate(observed, allowed_states:)
        with_generation_lock(observed.task_generation) do
          current = fetch(observed.attempt_id)
          verify_cas!(current, observed, allowed_states)
          replacement = Record.new(yield(current.to_h))
          verify_immutable!(current, replacement)
          persist(replacement)
          replacement
        end
      rescue InvalidRecord, InvalidOutputReference => e
        raise StoreError, e.message
      end

      def verify_cas!(current, observed, allowed_states)
        raise CompareAndSwapFailed, "attempt no longer exists" unless current
        unless current.attempt_id == observed.attempt_id &&
               current.task_generation == observed.task_generation &&
               current.state == observed.state &&
               current.lease_version == observed.lease_version &&
               current.active_deadline_value == observed.active_deadline_value &&
               allowed_states.include?(current.state)
          raise CompareAndSwapFailed, "attempt lease compare-and-swap lost"
        end
      end

      def verify_immutable!(before, after)
        changed = Record::IMMUTABLE_KEYS.reject { |key| before[key] == after[key] }
        return if changed.empty?

        raise StoreError, "attempt immutable identity changed: #{changed.join(', ')}"
      end

      def persist(record, expected_absent: false)
        path = record_path(record.attempt_id)
        status = optional_lstat(path)
        if expected_absent
          raise StoreError, "attempt #{record.attempt_id} already exists" if status
        elsif status
          validate_regular_file!(path, label: "attempt record", status: status)
        end
        Hive::AtomicFile.write(path, JSON.generate(record.to_h) + "\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(records_root)
        record
      rescue SystemCallError, IOError => e
        raise StoreError, "attempt record could not be persisted: #{e.message}"
      end

      def with_record_lock(attempt_id)
        path = File.join(generation_locks_root, "record-#{::Digest::SHA256.hexdigest(attempt_id.to_s)}.lock")
        open_lock(path) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def ensure_private_directories!
        managed_directories.each do |label, path|
          if label != "root" && File.symlink?(path)
            raise StoreError, "attempt store #{label} directory is a symlink"
          end

          FileUtils.mkdir_p(path, mode: 0o700) unless File.exist?(path)
          managed_directory_path(path, label: label)
          File.chmod(0o700, path)
        end
      rescue SystemCallError => e
        raise StoreError, "attempt store is unavailable: #{e.message}"
      end

      def managed_directories
        {
          "root" => @root,
          "records" => @records_root,
          "logs" => @logs_root,
          "outputs" => @outputs_root,
          "generation-locks" => @generation_locks_root
        }
      end

      def managed_directory_path(path, label:)
        if path == @root
          unless File.directory?(path)
            raise StoreError, "attempt store root path is not a directory"
          end

          return path
        end

        status = File.lstat(path)
        if status.symlink?
          raise StoreError, "attempt store #{label} directory is a symlink"
        end
        unless status.directory?
          raise StoreError, "attempt store #{label} path is not a directory"
        end

        validate_root_custody!(path, label: label)
        path
      rescue Errno::ENOENT
        return path unless @create_directories

        raise StoreError, "attempt store #{label} directory is missing"
      rescue SystemCallError => e
        raise StoreError, "attempt store #{label} directory is unavailable: #{e.message}"
      end

      def validate_root_custody!(path, label:)
        unless File.directory?(@root)
          raise StoreError, "attempt store root path is not a directory"
        end

        validate_descendant!(
          path,
          root: @root,
          error: "attempt store #{label} directory escapes the store root"
        )
      end

      def validate_regular_file!(path, label:, status: nil)
        status ||= File.lstat(path)
        raise StoreError, "#{label} is a symlink" if status.symlink?
        raise StoreError, "#{label} is not a regular file" unless status.file?

        path
      end

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def validate_output_custody!(path)
        validate_descendant!(
          path,
          root: outputs_root,
          error: "attempt output directory escapes the outputs root"
        )
      end

      def validate_descendant!(path, root:, error:)
        root_realpath = File.realpath(root)
        path_realpath = File.realpath(path)
        OutputReference.ensure_contained!(path_realpath, root_realpath)
      rescue InvalidOutputReference
        raise StoreError, error
      end

      def open_lock(path)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o600) do |lock|
          opened = lock.stat
          entry = File.lstat(path)
          raise StoreError, "attempt lock is a symlink" if entry.symlink?
          unless opened.file? && entry.file? &&
                 opened.dev == entry.dev && opened.ino == entry.ino
            raise StoreError, "attempt lock is not a regular file"
          end

          yield lock
        end
      rescue Errno::ELOOP
        raise StoreError, "attempt lock is a symlink"
      end

      def safe_id(value)
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)

        raise StoreError, "unsafe attempt id"
      end
    end
  end
end
