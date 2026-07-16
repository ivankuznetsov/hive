require "digest"
require "json"
require "fileutils"
require "hive/atomic_file"
require "hive/attempts/record"
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
      attr_reader :root, :records_root, :logs_root, :outputs_root, :generation_locks_root

      def initialize(root: Hive::Paths.attempts_root)
        @root = File.expand_path(root)
        @records_root = File.join(@root, "records")
        @logs_root = File.join(@root, "logs")
        @outputs_root = File.join(@root, "outputs")
        @generation_locks_root = File.join(@root, "generation-locks")
        ensure_private_directories!
      end

      def create_launching(**attributes)
        record = Record.launching(**attributes)
        path = record_path(record.attempt_id)
        with_record_lock(record.attempt_id) do
          raise StoreError, "attempt #{record.attempt_id} already exists" if File.exist?(path)

          persist(record)
        end
        record
      end

      def create_compatibility_running(**attributes)
        record = Record.compatibility_running(**attributes)
        path = record_path(record.attempt_id)
        with_record_lock(record.attempt_id) do
          raise StoreError, "attempt #{record.attempt_id} already exists" if File.exist?(path)

          persist(record)
        end
        record
      end

      def fetch(attempt_id)
        Record.new(JSON.parse(File.binread(record_path(attempt_id))))
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
            records << Record.new(JSON.parse(File.binread(path)))
          rescue JSON::ParserError, InvalidRecord, SystemCallError => e
            invalid << InvalidStoredRecord.new(path: path, error: e.message)
          end
        end
        Scan.new(records: records.freeze, invalid_records: invalid.freeze)
      end

      def for_generation(task_generation)
        scan.records.select { |record| record.task_generation == task_generation }
      end

      def claim(observed, owner:, first_heartbeat_timeout_sec:, now:)
        raise CompareAndSwapFailed, "launch claim deadline expired" if observed.active_deadline && now > observed.active_deadline
        mutate(observed, allowed_states: [ "launching" ]) do |data|
          raise CompareAndSwapFailed, "attempt is already claimed" if data["wrapper"]

          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "wrapper" => Record.deep_copy(owner),
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
          next_outputs = output_references.nil? ? data.fetch("current_outputs") : Record.deep_copy(output_references)
          next_outputs.each { |reference| OutputReference.validate_shape!(reference) }
          OutputReference.validate_shape!(log_reference) if log_reference
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "checkpoint" => Record.deep_copy(checkpoint),
            "latest_revision" => checkpoint["revision"] || checkpoint[:revision] || data["latest_revision"],
            "worker" => worker ? Record.deep_copy(worker) : data["worker"],
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
          "final_checkpoint" => Record.deep_copy(final_checkpoint),
          "output_references" => Record.deep_copy(output_references),
          "log_reference" => Record.deep_copy(log_reference)
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
            "checkpoint" => Record.deep_copy(final_checkpoint),
            "current_outputs" => Record.deep_copy(output_references),
            "log_reference" => Record.deep_copy(log_reference),
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
            "diagnostics" => data.fetch("diagnostics").merge(Record.deep_copy(diagnostics))
          )
        end
      end

      # Enrich an already-lost record after orphan cleanup / dirty capture.
      # The irreversible state and immutable identity remain unchanged.
      def annotate_lost(observed, output_references:, diagnostics:, now:)
        mutate(observed, allowed_states: [ "lost" ]) do |data|
          outputs = (data.fetch("current_outputs") + Record.deep_copy(output_references)).uniq
          outputs.each { |reference| OutputReference.validate_shape!(reference) }
          data.merge(
            "lease_version" => data.fetch("lease_version") + 1,
            "current_outputs" => outputs,
            "diagnostics" => data.fetch("diagnostics").merge(
              Record.deep_copy(diagnostics).merge("loss_processed_at" => Record.iso8601(now))
            )
          )
        end
      end

      def with_generation_lock(task_generation)
        path = generation_lock_path(task_generation)
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise StoreError, "attempt generation lock is unavailable: #{e.message}"
      end

      def record_path(attempt_id)
        File.join(records_root, "#{safe_id(attempt_id)}.json")
      end

      def generation_lock_path(task_generation)
        digest = ::Digest::SHA256.hexdigest(task_generation.to_s)
        File.join(generation_locks_root, "#{digest}.lock")
      end

      private

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

      def persist(record)
        path = record_path(record.attempt_id)
        Hive::AtomicFile.write(path, JSON.generate(record.to_h) + "\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(records_root)
        record
      rescue SystemCallError, IOError => e
        raise StoreError, "attempt record could not be persisted: #{e.message}"
      end

      def with_record_lock(attempt_id)
        path = File.join(generation_locks_root, "record-#{::Digest::SHA256.hexdigest(attempt_id.to_s)}.lock")
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def ensure_private_directories!
        [ root, records_root, logs_root, outputs_root, generation_locks_root ].each do |path|
          FileUtils.mkdir_p(path, mode: 0o700)
          File.chmod(0o700, path)
        end
      rescue SystemCallError => e
        raise StoreError, "attempt store is unavailable: #{e.message}"
      end

      def safe_id(value)
        string = value.to_s
        return string if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(string)

        raise StoreError, "unsafe attempt id"
      end
    end
  end
end
