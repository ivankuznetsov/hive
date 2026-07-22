require "json"
require "time"
require "fileutils"

module Hive
  module Daemon
    # Structured JSON-line logger for daemon events. One event per line;
    # closed `event` enum (any unknown name raises ArgumentError so a
    # typo crashes loudly at the call site instead of silently logging).
    # Size-rotated with a small bespoke rotator (stdlib Logger prepends
    # a header line that breaks JSON-line parsing — see ruby/logger).
    #
    # Each line is a self-contained JSON document with a stable shape:
    #   {ts: ISO8601, schema: "hive-daemon-log", schema_version: 1,
    #    event: <enum>, ...attrs}
    #
    # The enum is closed; new events require updating EVENTS plus a test
    # so adding an event without updating consumers is blocked at CI.
    class Logger
      SCHEMA = "hive-daemon-log".freeze
      SCHEMA_VERSION = 1

      EVENTS = %i[
        dispatcher_started
        legacy_layout_detected
        dispatcher_stopping
        tick_begin
        tick_end
        status_failure
        status_warning
        operational_snapshot_publish_failed
        dispatched
        skipped
        debouncing
        blocked
        child_exited
        child_terminated
        child_timeout
        config_reloaded
        project_dropped
        transient_retry
        quarantined
        dry_run
        marker_healed
        marker_heal_failed
        recovery_requested
        recovery_blocked
        display_name_backfill
        update_available
        update_check_no_result
        update_check_error
        update_nudge_no_command
        version_drift
        daemon_dispatch_baselines_corrupt
        daemon_dispatch_baselines_lock_error
        daemon_dispatch_baselines_write_error
        daemon_dispatch_baselines_tmp_sweep_error
        daemon_dispatch_baselines_unexpected_error
        daemon_dispatch_baselines_loaded
        daemon_dispatch_baselines_newer_schema_suspended
        dispatch_request_observed
        dispatch_request_dispatched
        dispatch_request_attached
        dispatch_request_terminal_replay
        dispatch_request_completed
        dispatch_request_rejected
        dispatch_request_blocked
        dispatch_request_expired
        dispatch_request_recovered
        dispatch_result_written
        attempt_accepted
        attempt_claimed
        attempt_running
        attempt_adopted
        attempt_suspect
        attempt_terminal
        attempt_lost
        attempt_duplicate
        attempt_terminal_replay
        attempt_capacity_deferred
        attempt_legacy_backfilled
        digest_catchup_skipped
        digest_failure_backoff
        digest_permanent_failure
        digest_state_unreadable
        answer_digest_failure_backoff
        answer_digest_state_unreadable
        architecture_patrol_opened
        architecture_patrol_progress
        architecture_patrol_closed
        architecture_patrol_blocked
        module_migration
        fatal
      ].freeze

      attr_reader :path

      def initialize(path:, max_bytes: 10_485_760, max_files: 5)
        @path = path
        @max_bytes = max_bytes
        @max_files = max_files
        @stderr_fallback = false
        FileUtils.mkdir_p(File.dirname(path))
        # Open once and keep the handle for the lifetime of the daemon.
        @file = File.open(path, "a")
      rescue Errno::EACCES, Errno::EROFS, Errno::ENOSPC, Errno::ENOENT => e
        @file = nil
        @stderr_fallback = true
        @stderr_fallback_reason = e.message
        warn "hive daemon: log file #{path} is unwritable (#{e.message}); falling back to stderr"
      end

      def event(name, **attrs)
        unless EVENTS.include?(name)
          raise ArgumentError, "unknown daemon log event: #{name.inspect} " \
                               "(valid: #{EVENTS.inspect})"
        end

        payload = {
          ts: Time.now.utc.iso8601,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          event: name.to_s
        }.merge(attrs.transform_keys(&:to_sym))

        line = JSON.generate(payload)
        if @stderr_fallback
          warn line
          return
        end

        rotate_if_needed!
        @file.puts(line)
        @file.flush
      end

      def close
        @file&.close
      end

      def stderr_fallback?
        @stderr_fallback
      end

      private

      def rotate_if_needed!
        return if @file.nil?
        return if file_size_for_rotation < @max_bytes

        @file.close
        # Roll older files out of the way: <path>.<N-2> → <path>.<N-1>,
        # <path>.0 → <path>.1, then <path> → <path>.0.
        (@max_files - 2).downto(0) do |i|
          src = i.zero? ? @path : "#{@path}.#{i - 1}"
          dst = "#{@path}.#{i}"
          # Skip the i=0 case where src == @path; that's handled below.
          if i.zero?
            File.rename(@path, "#{@path}.0") if File.exist?(@path)
          elsif File.exist?(src)
            File.rename(src, dst)
          end
        end
        @file = File.open(@path, "a")
      end

      def file_size_for_rotation
        @file.size
      rescue StandardError
        0
      end
    end
  end
end
