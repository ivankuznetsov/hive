module Hive
  module Patrol
    # Cooperative shutdown for the patrol child.
    #
    # The daemon stops by SIGTERMing its children and waiting
    # `shutdown_grace_sec` (600 by default) before SIGKILL. Every other
    # long-running child traps TERM; patrol did not, so a restart waited the
    # full grace and then force-killed a scan mid-agent. That forced kill is
    # what can strand an effect between prepare and settlement, which is the
    # state recovery is worst at resuming.
    #
    # Stopping is only ever checked at boundaries where no work is in flight,
    # so a requested shutdown costs the remainder of one cycle and never
    # abandons an effect. Patrol re-runs from its journal on the next tick.
    module Shutdown
      SIGNALS = %w[TERM INT].freeze

      module_function

      def install_trap!(signals: SIGNALS)
        signals.each do |signal|
          Signal.trap(signal) { @requested = true }
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
    end
  end
end
