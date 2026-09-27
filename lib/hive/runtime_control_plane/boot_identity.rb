require "digest"
require "etc"
require "hive/lock"

module Hive
  module RuntimeControlPlane
    # Stable host/boot binding for persisted monotonic deadlines. Monotonic
    # values cannot be compared across boots, so a missing or changed identity
    # always shortens work rather than extending a shutdown deadline.
    module BootIdentity
      module_function

      def current
        path = "/proc/sys/kernel/random/boot_id"
        value = File.read(path, 256).strip if File.file?(path)
        return value unless value.to_s.empty?

        init_start = Hive::Lock.process_start_time(1)
        return nil if init_start.to_s.empty?

        Digest::SHA256.hexdigest("#{Etc.uname[:nodename]}\0#{init_start}")
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
