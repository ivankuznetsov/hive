require "thread"

module Hive
  module Daemon
    module TransitionMetrics
      module_function

      def denied!(reason)
        mutex.synchronize { denials[reason.to_s] += 1 }
      end

      def snapshot
        mutex.synchronize { denials.dup }
      end

      def reset!
        mutex.synchronize { denials.clear }
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def denials
        @denials ||= Hash.new(0)
      end
    end
  end
end
