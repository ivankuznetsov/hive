require "hive"
require "hive/tui/debug"

module Hive
  module Tui
    # The Charm bubbletea + lipgloss backend's lifecycle owner. After
    # U11 this is the only TUI backend; the curses path was removed in
    # the same release. `HIVE_TUI_BACKEND=curses` now raises a typed
    # error pointing at the removal instead of routing to the legacy
    # code, and unsetting the env var (or setting it to "charm") boots
    # the charm runtime directly.
    module App
      CHARM = "charm".freeze
      KNOWN_BACKENDS = [ CHARM ].freeze

      # Recognized so a one-release-stale invocation gets a typed error
      # explaining the removal rather than `unknown HIVE_TUI_BACKEND`.
      REMOVED_BACKENDS = {
        "curses" => "the curses backend was removed; charm is the only supported backend. " \
                    "Unset HIVE_TUI_BACKEND or set it to 'charm'."
      }.freeze

      module_function

      def run
        backend
        run_charm
      end

      # Validates `HIVE_TUI_BACKEND`: returns the value when supported,
      # raises with a removal pointer for retired backends, and raises
      # `Hive::InvalidTaskPath` (exit 64) otherwise.
      def backend
        chosen = ENV.fetch("HIVE_TUI_BACKEND", CHARM).strip
        return chosen if KNOWN_BACKENDS.include?(chosen)
        raise Hive::InvalidTaskPath, REMOVED_BACKENDS.fetch(chosen) if REMOVED_BACKENDS.key?(chosen)

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

        # Pre-declare the cleanup-relevant locals so the ensure block
        # can nil-guard each one. Setup runs INSIDE begin so a raise
        # before runner.run still triggers the same cleanup path
        # (StateSource thread join, HUP hook restore, in-flight
        # subprocess + heal thread reap). Pre-fix, a Bubbletea::Runner
        # constructor failure would leak the StateSource thread.
        state_source = nil
        bubble_model = nil
        prev_hup = nil
        poller = nil

        begin
          state_source = Hive::Tui::StateSource.new
          state_source.start

          seed_model = Hive::Tui::Model.initial
          bubble_model = Hive::Tui::BubbleModel.new(hive_model: seed_model)
          # `input_timeout: 1` (ms) is the GVL-friendly setting: bubbletea-ruby's
          # `tea_input_read_raw` C call holds the Ruby GVL for the full timeout
          # without releasing it, which starves the StateSource polling thread
          # at the default 10ms. With 1ms, the main loop yields the GVL ~10x
          # more often per second so background snapshot polling lands within
          # ~1s instead of stalling for 10s+. Documented in
          # `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.
          runner = Bubbletea::Runner.new(bubble_model, alt_screen: true, input_timeout: 1)
          bubble_model.dispatch = runner.method(:send)

          prev_hup = install_terminate_hook(runner)
          poller = start_snapshot_poller(state_source, runner)

          runner.run
        ensure
          poller&.kill
          state_source&.stop
          restore_terminate_hook(prev_hup) if prev_hup
          Hive::Tui::SubprocessRegistry.kill_inflight!
          # F8: heal Threads spawned by auto-heal can outlive the
          # runner; reap them with a 2s join-then-kill so the process
          # doesn't exit with zombies.
          bubble_model&.kill_inflight_heals!
        end
      end

      # @api private
      # Background thread that pulls snapshots from StateSource at ~0.5s
      # cadence and injects them into the runner as SnapshotArrived /
      # PollFailed messages. StateSource is the source of truth for the
      # actual polling cadence (1 Hz); this thread just drives the
      # message-pump side and dedupes back-to-back identical snapshots.
      #
      # The thread's outer loop catches StandardError so a transient
      # exception in StateSource doesn't kill the messenger; the loop
      # ends when the runner's `ensure` block calls `poller.kill`.
      def start_snapshot_poller(state_source, runner)
        Thread.new do
          last_snapshot = nil
          last_dispatched_error = nil
          loop do
            sleep 0.5
            current = state_source.current
            error = state_source.last_error
            if current && current != last_snapshot
              runner.send(Hive::Tui::Messages::SnapshotArrived.new(snapshot: current))
              last_snapshot = current
              # Reset the error-dedup so a future failure-after-success
              # gets dispatched (otherwise an error from before the
              # success would shadow a fresh one).
              last_dispatched_error = nil
            elsif error && !error.equal?(last_dispatched_error)
              # Identity dedup so the same exception isn't re-dispatched
              # every 0.5s tick while StateSource holds it. Two distinct
              # exceptions (even with identical messages) dispatch
              # separately.
              runner.send(Hive::Tui::Messages::PollFailed.new(error: error))
              last_dispatched_error = error
            end
          rescue StandardError => e
            # Defensive: never let the poller thread die. Log so a real
            # bug here can be diagnosed via `HIVE_TUI_DEBUG=1` —
            # without this, the loop livelocked invisibly: sleep, fail,
            # next, repeat with no observability anywhere.
            Hive::Tui::Debug.log("poller", "rescued #{e.class.name}: #{e.message}")
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
