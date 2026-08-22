module Hive
  module Patrol
    # Cooperative shutdown for the patrol child.
    #
    # The daemon stops by SIGTERMing its children and waiting
    # `shutdown_grace_sec` (600 by default) before SIGKILL. Every other
    # long-running child traps TERM; patrol did not, so a restart waited the
    # full grace and then force-killed a scan mid-agent.
    #
    # Stopping is only ever checked at boundaries where no work is in flight,
    # so a requested shutdown costs the remainder of one cycle and never
    # abandons an in-flight agent call. Patrol resumes from its native scan
    # state on the next tick.
    module Shutdown
      SIGNALS = %w[TERM INT].freeze

      module_function

      def install_trap!(signals: SIGNALS)
        signals.each do |signal|
          previous = nil
          previous = Signal.trap(signal) do |number|
            @requested = true
            call_previous_handler(previous, number)
          end
        rescue ArgumentError
          # A platform without this signal simply keeps the default handler.
          nil
        end
      end

      def requested?
        @requested == true
      end

      def request!
        @requested = true
      end

      def reset!
        @requested = false
      end

      def call_previous_handler(handler, signal)
        return unless handler.respond_to?(:call)

        handler.arity.zero? ? handler.call : handler.call(signal)
      end
      private_class_method :call_previous_handler
    end
  end
end
