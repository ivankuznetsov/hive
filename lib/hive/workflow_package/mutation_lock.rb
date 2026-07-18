require "fileutils"

module Hive
  module WorkflowPackage
    module MutationLock
      module_function

      def with_lock(workflows_dir, shared: false)
        FileUtils.mkdir_p(workflows_dir)
        path = File.join(workflows_dir, ".mutation.lock")
        File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      rescue SystemCallError, IOError => e
        raise Hive::ConcurrentRunError.new("workflow mutation lock failed: #{e.message}", lock_path: path)
      end
    end
  end
end
