require "monitor"

module Hive
  module Tui
    # Process-local registry for the single in-flight workflow-verb child the
    # TUI may spawn at a time. Holds either nil, a `:placeholder` sentinel
    # (between `Process.spawn` start and `getpgid` return), or an Integer
    # pgid. Read by the SIGHUP cleanup hook in U9; written by Subprocess
    # before/after the spawn.
    #
    # A `Monitor` (re-entrant) — not a plain Mutex — guards the slot so a
    # signal trap firing while #register is mid-flight on the same thread
    # doesn't deadlock. Trap context limits what the kill path can do, so
    # `kill_inflight!` is kept short and allocation-free on the hot path:
    # no string interpolation, no Hash#each, just one kill + rescue + clear.
    module SubprocessRegistry
      MONITOR = Monitor.new

      # Module-level mutable state. The Monitor wraps every read/write so
      # the SIGHUP trap reads a coherent value rather than a torn one.
      @slot = nil

      module_function

      def register_placeholder
        MONITOR.synchronize { @slot = :placeholder }
      end

      def register(pgid)
        MONITOR.synchronize { @slot = pgid }
      end

      def clear
        MONITOR.synchronize { @slot = nil }
      end

      def current
        MONITOR.synchronize { @slot }
      end

      # Trap-context-safe: trivial branch on a fixed type, single Process.kill
      # with a narrow rescue, then clear. Returns nil in every branch so
      # callers (and trap bodies) don't have to inspect the result.
      def kill_inflight!
        MONITOR.synchronize do
          slot = @slot
          @slot = nil
          return nil unless slot.is_a?(Integer)

          begin
            Process.kill("TERM", -slot)
          rescue Errno::ESRCH, Errno::EPERM
            # ESRCH: the group already exited; EPERM: ownership lost. Both
            # are acceptable end-states for a "kill the in-flight child" hook.
            nil
          end
        end
        nil
      end
    end
  end
end
