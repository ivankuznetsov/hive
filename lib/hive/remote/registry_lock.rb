# frozen_string_literal: true

require "hive/lock"

module Hive
  module Remote
    module RegistryLock
      TIMEOUT_SECONDS = 1.0
      module_function

      def acquire!(file, mode, timeout: TIMEOUT_SECONDS)
        deadline = Hive::Lock.monotonic_now + timeout
        until file.flock(mode | File::LOCK_NB)
          remaining = deadline - Hive::Lock.monotonic_now
          unless remaining.positive?
            raise Hive::ConcurrentRunError.new("private registry is busy; retry", lock_path: file.path)
          end
          sleep [ remaining, 0.01 ].min
        end
      end
    end
  end
end
