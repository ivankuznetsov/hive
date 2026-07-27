require "digest"
require "fileutils"

module Hive
  module WorkflowPackage
    module PublishLock
      module_function

      def with_lock(root, identity)
        locks = File.join(root, "locks")
        ensure_private_directory!(root)
        ensure_private_directory!(locks)
        path = File.join(locks, "#{::Digest::SHA256.hexdigest(identity.to_s)}.lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        file = File.open(path, flags, 0o600)
        File.chmod(0o600, path)
        file.flock(File::LOCK_EX)
        yield
      rescue SystemCallError, IOError => e
        raise Hive::ConcurrentRunError.new("workflow publication lock failed: #{e.message}", lock_path: path)
      ensure
        file&.flock(File::LOCK_UN) rescue nil
        file&.close rescue nil
      end

      def ensure_private_directory!(path)
        if File.exist?(path) || File.symlink?(path)
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
            raise PublishRecoveryError, "workflow publication state directory is not owner-private"
          end
        else
          FileUtils.mkdir_p(path, mode: 0o700)
          File.chmod(0o700, path)
        end
        path
      end
    end
  end
end
