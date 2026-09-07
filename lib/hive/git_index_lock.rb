require "open3"
require "securerandom"

module Hive
  # Only used while holding Hive's state-repository commit lock. Git may close
  # an index lock before renaming it, so an open-file probe alone is not enough.
  module GitIndexLock
    module_function

    def recover!(root)
      output, _, status = Open3.capture3("git", "-C", root, "rev-parse", "--path-format=absolute", "--git-path", "index.lock")
      return unless status.success?

      path = output.strip
      original = File.lstat(path)
      return unless original.file? && original.size.zero? && original.uid == Process.uid
      return unless Time.now - original.mtime > 60
      return unless no_writers?(path)
      current = File.lstat(path)
      return unless [ current.dev, current.ino, current.mtime, current.size ] ==
                    [ original.dev, original.ino, original.mtime, original.size ]

      # Preserve crash residue for inspection rather than deleting it.
      File.rename(path, "#{path}.hive-stale-#{SecureRandom.hex(8)}")
      warn "hive: recovered abandoned Git index lock in #{root}"
    rescue SystemCallError, IOError
      # Missing tools, inaccessible process state, or a disappearing lock do
      # not grant authority to remove anything. The normal Git error survives.
      nil
    end

    def no_writers?(path)
      processes, errors, status = Open3.capture3("ps", "-eo", "comm=")
      return false unless status.success? && errors.empty?
      return false if processes.lines.any? { |line| File.basename(line.strip).match?(/\Agit(?:\z|[- ])/) }

      holders, errors, status = Open3.capture3("fuser", "--", path)
      status.exitstatus == 1 && holders.empty? && errors.empty?
    end
  end
end
