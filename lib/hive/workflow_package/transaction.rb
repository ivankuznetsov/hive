require "hive/atomic_file"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/transaction_journal"

module Hive
  module WorkflowPackage
    class Transaction
      def self.activate(lock_path:, workflows_dir:, new_lock:, commit: nil)
        new(lock_path: lock_path, workflows_dir: workflows_dir).activate(new_lock, commit: commit)
      end

      def self.remove(lock_path:, workflows_dir:, commit: nil)
        new(lock_path: lock_path, workflows_dir: workflows_dir).remove(commit: commit)
      end

      def initialize(lock_path:, workflows_dir:)
        @lock_path = lock_path
        @journal = TransactionJournal.new(workflows_dir)
      end

      def activate(new_lock, commit: nil)
        old_bytes = File.binread(@lock_path) if File.file?(@lock_path)
        new_bytes = CanonicalJSON.generate(new_lock)
        run(old_bytes, new_bytes, commit)
      end

      def remove(commit: nil)
        old_bytes = File.binread(@lock_path) if File.file?(@lock_path)
        run(old_bytes, nil, commit)
      end

      def reconcile!
        data = @journal.read
        return false unless data

        restore(data["old_lock"])
        @journal.clear
        true
      end

      private

      def run(old_bytes, new_bytes, commit)
        @journal.write("schema_version" => 1, "phase" => "prepared", "lock_path" => @lock_path,
                       "old_lock" => old_bytes, "new_lock" => new_bytes)
        write_pointer(new_bytes)
        @journal.write("schema_version" => 1, "phase" => "pointer_written", "lock_path" => @lock_path,
                       "old_lock" => old_bytes, "new_lock" => new_bytes)
        commit&.call
        @journal.clear
        true
      rescue StandardError
        restore(old_bytes)
        @journal.clear
        raise
      end

      def write_pointer(bytes)
        if bytes
          Hive::AtomicFile.write(@lock_path, bytes, mode: 0o600)
        else
          FileUtils.rm_f(@lock_path)
        end
      end

      def restore(bytes)
        write_pointer(bytes)
      end
    end
  end
end
