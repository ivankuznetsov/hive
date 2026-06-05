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

      # Upper bound on how long the mtime gate may reuse a cached
      # snapshot before forcing a full re-parse. The fingerprint only
      # tracks file mtimes, but some payload fields (`live_task_lock`,
      # `claude_pid_alive`) are derived from process liveness, which
      # flips without touching any file. Without this fallback a dead
      # lock holder's "live" indicator could never clear. The bound
      # keeps the indicator self-healing while still skipping most
      # idle-path parses.
      LIVENESS_REPARSE_FALLBACK_SECONDS = 3.0

      def initialize(poll_interval_seconds: 1.0)
        @poll_interval_seconds = poll_interval_seconds
        @current = nil
        @current_seen_at = nil
        @last_error = nil
        @mtime_fingerprint = nil
        @last_full_parse_at = nil
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
        if @current && @mtime_fingerprint && mtime_fingerprint_unchanged? && !full_reparse_due?
          @current_seen_at = Time.now
          @last_error = nil
          return
        end

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        snapshot = Snapshot.from_payload(payload)
        @current = snapshot
        @current_seen_at = Time.now
        @last_full_parse_at = @current_seen_at
        @mtime_fingerprint = mtime_fingerprint_for(snapshot)
        @last_error = nil
      rescue StandardError => e
        @last_error = e
      end

      # Time-bounded fallback so the mtime gate can't mask liveness
      # state indefinitely (see LIVENESS_REPARSE_FALLBACK_SECONDS).
      def full_reparse_due?(now: Time.now)
        return true if @last_full_parse_at.nil?

        (now - @last_full_parse_at) >= LIVENESS_REPARSE_FALLBACK_SECONDS
      end

      def mtime_fingerprint_unchanged?
        return false if @mtime_fingerprint.empty?

        @mtime_fingerprint.all? do |path, previous_mtime|
          safe_mtime(path) == previous_mtime
        end
      end

      def mtime_fingerprint_for(snapshot)
        # Watch the global project registry too: `hive init`/`forget`
        # rewrite config.yml without touching any tracked state file,
        # so without this the gate would never see a project added or
        # removed and the displayed set would go stale indefinitely.
        paths = [ registry_config_path ]
        snapshot.projects.each do |project|
          paths.concat(project_watch_paths(project))
          project.rows.each { |row| paths << row.state_file }
        end
        paths.compact.uniq.to_h { |path| [ path, safe_mtime(path) ] }
      end

      def registry_config_path
        Hive::Config.global_config_path
      rescue StandardError
        nil
      end

      def project_watch_paths(project)
        stages_dir = File.join(project.hive_state_path.to_s, "stages")
        [ stages_dir, *Dir.glob(File.join(stages_dir, "*")) ]
      end

      def safe_mtime(path)
        File.mtime(path) if path && File.exist?(path)
      rescue StandardError
        nil
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
