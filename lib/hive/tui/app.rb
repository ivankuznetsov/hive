require "hive"

module Hive
  module Tui
    # Backend dispatcher. Reads `HIVE_TUI_BACKEND` env var:
    #   unset / "charm" → bubbletea + lipgloss path (default after U10)
    #   "curses"        → legacy curses run loop (kept until U11)
    # Anything else raises `Hive::InvalidTaskPath` (exit 64) — same shape as
    # the `--json` rejection at the command boundary.
    #
    # The dispatcher exists for the duration of the migration only. U11
    # deletes the curses branch; the env var is then recognized one more
    # release as a graceful-error pointer at the removal, then dropped.
    module App
      CURSES = "curses".freeze
      CHARM = "charm".freeze
      KNOWN_BACKENDS = [ CURSES, CHARM ].freeze

      module_function

      def run
        case backend
        when CURSES
          Hive::Tui.run_curses
        when CHARM
          run_charm
        end
      end

      # Default flipped to charm in U10. Setting `HIVE_TUI_BACKEND=curses`
      # remains supported for one release as an escape hatch in case a
      # user hits a charm-specific regression on their terminal.
      def backend
        chosen = ENV.fetch("HIVE_TUI_BACKEND", CHARM).strip
        return chosen if KNOWN_BACKENDS.include?(chosen)

        raise Hive::InvalidTaskPath,
              "unknown HIVE_TUI_BACKEND: #{chosen.inspect} (expected one of: #{KNOWN_BACKENDS.join(', ')})"
      end

      # Charm backend's full lifecycle: requires bubbletea + lipgloss
      # lazily (so unit tests that don't enter run_charm don't depend
      # on the FFI extension being loadable), boots a StateSource, wires
      # SIGHUP / poll / runner, and runs the Bubble Tea program until
      # the model returns Bubbletea.quit.
      def run_charm
        require "bubbletea"
        require "hive/tui/bubble_model"
        require "hive/tui/state_source"
        require "hive/tui/subprocess_registry"

        state_source = Hive::Tui::StateSource.new
        state_source.start

        seed_model = Hive::Tui::Model.initial
        bubble_model = Hive::Tui::BubbleModel.new(hive_model: seed_model)
        runner = Bubbletea::Runner.new(bubble_model, alt_screen: true)
        bubble_model.dispatch = runner.method(:send)

        prev_hup = install_terminate_hook(runner)
        poller = start_snapshot_poller(state_source, runner)

        begin
          runner.run
        ensure
          poller&.kill
          state_source.stop
          restore_terminate_hook(prev_hup)
          Hive::Tui::SubprocessRegistry.kill_inflight!
        end
      end

      # @api private
      # Background thread that pulls snapshots from StateSource at ~1Hz
      # and injects them into the runner as SnapshotArrived / PollFailed
      # messages. StateSource is the source of truth for the polling
      # cadence; this thread just drives the message-pump side.
      #
      # The thread's outer loop catches StandardError so a transient
      # exception in StateSource doesn't kill the messenger; the loop
      # ends when StateSource#stop is called (its thread exits, leaving
      # `current` frozen on the last successful snapshot).
      def start_snapshot_poller(state_source, runner)
        Thread.new do
          last_snapshot = nil
          loop do
            sleep 0.5
            current = state_source.current
            error = state_source.last_error
            if current && current != last_snapshot
              runner.send(Hive::Tui::Messages::SnapshotArrived.new(snapshot: current))
              last_snapshot = current
            elsif error
              runner.send(Hive::Tui::Messages::PollFailed.new(error: error))
            end
          rescue StandardError
            # Defensive: never let the poller thread die. The render loop
            # will keep showing the last snapshot until something else
            # kills the program.
            next
          end
        end
      end

      # SIGHUP cooperative cancellation: the trap fires from a separate
      # thread (Ruby signal-handler context), so we use `runner.send` to
      # enqueue a TerminateRequested message rather than touching state
      # directly. The runner picks it up at the top of its next loop tick.
      def install_terminate_hook(runner)
        Signal.trap("HUP") do
          runner.send(Hive::Tui::Messages::TERMINATE_REQUESTED)
        end
      end

      def restore_terminate_hook(prev)
        Signal.trap("HUP", prev || "DEFAULT")
      rescue ArgumentError
        nil
      end
    end
  end
end
