require "fileutils"

module Hive
  module WorkflowPackage
    module MutationLock
      module_function

      def with_lock(workflows_dir, shared: false)
        path = File.join(workflows_dir, ".mutation.lock")
        file = nil
        begin
          FileUtils.mkdir_p(workflows_dir)
          file = File.open(path, File::RDWR | File::CREAT, 0o600)
          file.flock(shared ? File::LOCK_SH : File::LOCK_EX)
        rescue SystemCallError, IOError => e
          file&.close
          raise Hive::ConcurrentRunError.new("workflow mutation lock failed: #{e.message}", lock_path: path)
        end

        begin
          yield
        ensure
          file.flock(File::LOCK_UN) rescue nil
          file.close rescue nil
        end
      end
    end
  end
end
