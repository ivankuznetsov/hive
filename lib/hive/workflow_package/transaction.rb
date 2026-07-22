require "hive/atomic_file"
require "open3"
require "pathname"
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

        bytes = case data.fetch("phase")
        when "prepared", "pointer_written"
          data["old_lock"]
        when "commit_started"
          committed_pointer?(data["new_lock"]) ? data["new_lock"] : data["old_lock"]
        when "commit_completed"
          data["new_lock"]
        else
          raise Hive::ConfigError, "managed workflow transaction journal has an unsupported phase"
        end
        restore(bytes)
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
        if commit
          @journal.write("schema_version" => 1, "phase" => "commit_started", "lock_path" => @lock_path,
                         "old_lock" => old_bytes, "new_lock" => new_bytes)
          commit.call
          @journal.write("schema_version" => 1, "phase" => "commit_completed", "lock_path" => @lock_path,
                         "old_lock" => old_bytes, "new_lock" => new_bytes)
        end
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

      def committed_pointer?(expected_bytes)
        root_out, _root_err, root_status = Open3.capture3(
          "git", "-C", File.dirname(@lock_path), "rev-parse", "--show-toplevel"
        )
        return false unless root_status.success?

        root = root_out.strip
        relative_path = Pathname.new(@lock_path).relative_path_from(Pathname.new(root)).cleanpath
        return false if relative_path.absolute? || relative_path.each_filename.include?("..")

        relative = relative_path.to_s
        if expected_bytes
          entry, _err, status = Open3.capture3(
            "git", "-C", root, "ls-tree", "-z", "HEAD", "--", relative
          )
          return false unless status.success?

          object_id = entry.match(/\A\d+ blob ([0-9a-f]{40,64})\t/)&.captures&.first
          return false unless object_id

          actual, _err, status = Open3.capture3("git", "-C", root, "cat-file", "blob", object_id)
          status.success? && actual.b == expected_bytes.b
        else
          listed, _err, status = Open3.capture3(
            "git", "-C", root, "ls-tree", "--full-tree", "--name-only", "HEAD", "--", relative
          )
          status.success? && listed.strip.empty?
        end
      rescue ArgumentError, SystemCallError, IOError
        false
      end
    end
  end
end
