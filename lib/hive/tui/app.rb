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
        require "hive/tui/paste_aware_runner"
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
        prev_winch = nil
        poller = nil

        begin
          state_source = Hive::Tui::StateSource.new
          # Synchronous prime: refresh_now runs one in-process status parse
          # and returns the seed snapshot BEFORE the background poller starts,
          # so the first Bubbletea frame renders real rows instead of a loading
          # grid. The input loop would otherwise starve the poll thread for
          # seconds (see input_timeout note below). Capture both seed values
          # here, ahead of `start`, so the model is seeded from a deterministic
          # snapshot rather than racing the first background poll.
          seed_snapshot = state_source.refresh_now
          seed_error = state_source.last_error
          state_source.start

          seed_model = Hive::Tui::Model.initial.with(
            snapshot: seed_snapshot,
            last_error: seed_error
          )
          bubble_model = Hive::Tui::BubbleModel.new(hive_model: seed_model)
          # `input_timeout: 5` (ms) trades a tiny amount of GVL-yield
          # latency for substantially less escape-sequence fragmentation.
          # bubbletea-ruby's `tea_input_read_raw` C call holds the GVL for
          # the full timeout, so a 1ms window starved the StateSource
          # poller; 5ms still yields the GVL frequently enough for the
          # background snapshot poll to land within ~1s, while giving
          # the InputDecoder a wider window to absorb a fragmented
          # PASTE_START / multi-byte arrow sequence in a single read
          # (a 1ms window split `\e[200~` into two reads on a slow
          # terminal, so paste markers were emitted as Esc + literal
          # `[200~`). YieldTick is the primary GVL-yield mechanism; this
          # value just shapes how aggressively input is polled.
          # Documented in
          # `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.
          # Follow-up: benchmark on a real slow tty (ssh-over-mobile).
          runner = runner_class.new(
            bubble_model,
            alt_screen: true,
            input_timeout: 5,
            bracketed_paste: true,
            mouse_cell_motion: true
          )
          bubble_model.dispatch = runner.method(:send)

          prev_hup = install_terminate_hook(runner)
          prev_winch = install_resize_hook(runner)
          poller = start_snapshot_poller(state_source, runner)

          runner.run
        ensure
          poller&.kill
          state_source&.stop
          restore_terminate_hook(prev_hup) if prev_hup
          restore_resize_hook(prev_winch) if prev_winch
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

      def runner_class
        require "hive/tui/paste_aware_runner"
        Hive::Tui::PasteAwareRunner
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

      # Bubbletea-ruby installs its own SIGWINCH handler inside
      # Runner#run. Installing Hive's hook first lets the runner chain
      # back to us, so the app model receives a typed WindowSized even
      # if the framework's private resize path changes.
      def install_resize_hook(runner, output: $stdout)
        previous = Signal.trap("WINCH") do
          dispatch_terminal_size(runner, output: output)
        end
        dispatch_terminal_size(runner, output: output)
        previous
      rescue ArgumentError
        nil
      end

      def restore_resize_hook(prev)
        Signal.trap("WINCH", prev || "DEFAULT")
      rescue ArgumentError
        nil
      end

      def dispatch_terminal_size(runner, output: $stdout)
        message = terminal_size_message(output: output)
        return false unless message

        runner.send(message)
        true
      rescue StandardError => e
        Hive::Tui::Debug.log("resize", "ignored #{e.class.name}: #{e.message}")
        false
      end

      def terminal_size_message(output: $stdout)
        require "io/console"

        rows, cols = output.winsize
        rows = rows.to_i
        cols = cols.to_i
        return nil unless rows.positive? && cols.positive?

        Hive::Tui::Messages::WindowSized.new(cols: cols, rows: rows)
      rescue IOError, NoMethodError, SystemCallError
        nil
      end
    end
  end
end
