require "hive"
require "hive/commands/status"
require "hive/config"
require "hive/tui/snapshot"

module Hive
  module Tui
    # Background-thread poller for `hive status` JSON. Calls
    # `Hive::Commands::Status#json_payload` in-process at ~1 Hz, wraps
    # each successful payload in a Snapshot, and exposes the latest one
    # through `#current` for the render thread to read.
    #
    # The render thread reads `@current` without a Mutex. Under MRI's
    # GVL a pointer-sized reference assignment is atomic, so the reader
    # always sees either the previous Snapshot or the new one — never a
    # torn value. JRuby/TruffleRuby would need synchronisation; the boot
    # guard in `Hive::Tui.run` enforces MRI.
    #
    # On any StandardError during refresh the previous snapshot is held
    # and the failure is recorded in `@last_error` (overwritten each
    # retry; not a ring buffer, so the renderer only ever displays the
    # most recent error). The polling loop never crashes its own thread.
    class StateSource
      attr_reader :last_error, :current_seen_at

      def initialize(poll_interval_seconds: 1.0)
        @poll_interval_seconds = poll_interval_seconds
        @current = nil
        @current_seen_at = nil
        @last_error = nil
        @stop = false
        @thread = nil
      end

      # Latest Snapshot, or nil before the first successful poll.
      def current
        @current
      end

      # Boots the polling thread. Idempotent: a second call while the
      # thread is alive is a no-op so accidental double-starts in test
      # setup don't leak threads.
      def start
        return if @thread&.alive?

        @stop = false
        @thread = Thread.new { poll_loop }
      end

      # Sets the stop sentinel and joins the thread with a 0.5s
      # deadline. The loop checks the sentinel between 0.05s sleep
      # slices so this returns fast enough for test teardown to assert
      # the thread is no longer in `Thread.list`.
      def stop
        @stop = true
        thread = @thread
        @thread = nil
        thread&.join(0.5)
        nil
      end

      # Boot state (no successful poll yet) counts as stalled so the
      # renderer can show a "loading" banner before the first frame.
      def stalled?(now: Time.now, threshold_seconds: 5.0)
        return true if @current_seen_at.nil?

        (now - @current_seen_at) > threshold_seconds
      end

      private

      def poll_loop
        until @stop
          refresh_once
          sleep_in_slices(@poll_interval_seconds)
        end
      end

      def refresh_once
        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        snapshot = Snapshot.from_payload(payload)
        @current = snapshot
        @current_seen_at = Time.now
        @last_error = nil
      rescue StandardError => e
        @last_error = e
      end

      # Sleep in 0.05s slices so #stop joins quickly. Reading @stop
      # between slices is the same unsynchronised-reference-read pattern
      # the render thread uses on @current — safe under MRI's GVL.
      def sleep_in_slices(total_seconds)
        slice = 0.05
        elapsed = 0.0
        while elapsed < total_seconds && !@stop
          remaining = total_seconds - elapsed
          sleep(remaining < slice ? remaining : slice)
          elapsed += slice
        end
      end
    end
  end
end
