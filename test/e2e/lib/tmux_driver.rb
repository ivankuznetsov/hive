require "open3"
require "securerandom"
require "shellwords"
require "time"

module Hive
  module E2E
    class TmuxDriver
      class AnchorTimeout < StandardError
        attr_reader :captured, :anchor, :elapsed

        def initialize(anchor:, captured:, elapsed:)
          @anchor = anchor
          @captured = captured
          @elapsed = elapsed
          super("timed out waiting for #{anchor.inspect} after #{format('%.2f', elapsed)}s")
        end
      end

      class DeadSession < StandardError; end
      class PaneCollapsedError < StandardError; end
      class TmuxCommandTimeout < StandardError
        attr_reader :stdout, :stderr, :elapsed

        def initialize(stdout:, stderr:, elapsed:)
          @stdout = stdout
          @stderr = stderr
          @elapsed = elapsed
          super("tmux command timed out after #{format('%.2f', elapsed)}s")
        end
      end

      # Raised when a TUI-dispatched subprocess emits END[<id>] with a
      # non-zero exit. Carries the BEGIN/END id for cross-referencing with
      # the marker log + the captured log window for forensic display.
      class SubprocessFailed < StandardError
        attr_reader :begin_id, :exit_code, :log

        def initialize(begin_id:, exit_code:, log:)
          @begin_id = begin_id
          @exit_code = exit_code
          @log = log
          super("tui subprocess END[#{begin_id}] exit=#{exit_code}")
        end
      end

      # Raised when an ERRNO line appears in the watched marker window —
      # the subprocess crashed before reaching END, so no exit_code exists.
      class SubprocessAbnormal < StandardError
        attr_reader :begin_id, :log

        def initialize(begin_id:, log:)
          @begin_id = begin_id
          @log = log
          super("tui subprocess crashed before END (ERRNO observed for BEGIN[#{begin_id || '?'}])")
        end
      end

      # Common bash/zsh prompt sentinels we treat as "the TUI just exited and a
      # shell is staring back at us". Detected at end-of-pane to avoid false
      # positives on prompt-shaped strings inside the TUI itself.
      SHELL_PROMPT_RE = /[$#] \z/

      attr_reader :socket_name, :session_name, :keystrokes
      TMUX_COMMAND_TIMEOUT = 5.0

      def self.available?
        _out, _err, status = Open3.capture3("tmux", "-V")
        status.success?
      rescue Errno::ENOENT
        false
      end

      def initialize(run_id:, session_name:, command:, env: {}, rows: 50, cols: 200, subprocess_log_path: nil)
        @socket_name = "hive-e2e-#{run_id}"
        @session_name = session_name
        @command = command
        @env = env
        @rows = rows
        @cols = cols
        @keystrokes = []
        @started = false
        @subprocess_log_path = subprocess_log_path
        @subprocess_log_offset = subprocess_log_size
      end

      def start
        return if @started

        args = base_args + [
          "new-session", "-d", "-P", "-F", "\#{session_id}",
          "-s", @session_name, "-x", @cols.to_s, "-y", @rows.to_s
        ]
        args << command_with_env
        out, err, status = capture_command(*args)
        raise "tmux new-session failed: #{err.empty? ? out : err}" unless status.success?

        @tmux_session_id = out.strip
        @started = true
      end

      def send_keys(keys, literal: false)
        start
        args = base_args + [ "send-keys", "-t", @session_name ]
        args << "-l" if literal
        Array(keys).each { |key| args << key.to_s }
        out, err, status = capture_command(*args)
        raise "tmux send-keys failed: #{err.empty? ? out : err}" unless status.success?

        @keystrokes << { "at" => Time.now.utc.iso8601, "keys" => Array(keys).map(&:to_s), "literal" => literal }
      end

      def mark_subprocess_log!
        @subprocess_log_offset = subprocess_log_size
      end

      def send_text(text)
        text.to_s.each_char { |char| send_keys(char, literal: true) }
      end

      def send_text_chunk(text)
        send_keys(text.to_s, literal: true)
      end

      def capture_pane
        start
        ensure_live!
        out, err, status = capture_command(*(base_args + [ "capture-pane", "-p", "-t", @session_name ]))
        raise "tmux capture-pane failed: #{err.empty? ? out : err}" unless status.success?

        out
      end

      # `require_stable: true` forces a second capture after a positive anchor
      # match before returning :ok. This avoids false positives where the anchor
      # text appears mid-render (e.g. between scroll lines while the TUI is still
      # writing) — without it we can hand back control to the next step before
      # the screen has actually settled.
      #
      # Predicate ordering (race avoidance):
      #   1. capture-pane FIRST — get a deterministic snapshot to reason over.
      #   2. Detect a shell-prompt sentinel at the tail of the snapshot. If the
      #      TUI has already exited, the surrounding shell prompt is what we
      #      see, and continuing to wait is pointless: fail fast with
      #      PaneCollapsedError so the scenario surfaces a clear cause.
      #   3. Match the anchor against the snapshot.
      #   4. Run has-session as a final verification before declaring :ok, in
      #      case the session died DURING capture-pane (capture races process
      #      teardown otherwise).
      # The settled-state stabilization branch applies the same order on both
      # polls of the two-poll-stable confirmation.
      def wait_for(anchor: nil, timeout: 3.0, interval: 0.1, allow_stable: true, require_stable: true)
        start
        started_at = monotonic_time
        previous = nil
        stable_count = 0
        last = +""

        loop do
          last = capture_pane_raw
          guard_pane_collapsed!(last)
          if anchor && last.include?(anchor)
            unless require_stable
              ensure_live!
              return :ok
            end

            sleep interval
            confirm = capture_pane_raw
            guard_pane_collapsed!(confirm)
            if confirm.include?(anchor) && confirm == last
              ensure_live!
              return :ok
            end

            previous = confirm
            last = confirm
          end

          if allow_stable && !anchor.nil? && last == previous
            stable_count += 1
            if stable_count >= 2
              ensure_live!
              return :ok
            end
          else
            stable_count = 0
          end
          previous = last

          elapsed = monotonic_time - started_at
          raise AnchorTimeout.new(anchor: anchor, captured: last, elapsed: elapsed) if elapsed >= timeout

          sleep interval
        end
      end

      private def guard_pane_collapsed!(pane)
        return unless pane.is_a?(String) && !pane.empty?

        tail = pane.lines.last(3).join
        raise PaneCollapsedError, "tmux pane collapsed to a shell prompt; subprocess exited" if SHELL_PROMPT_RE.match?(tail)
      end

      private def capture_pane_raw
        out, err, status = capture_command(*(base_args + [ "capture-pane", "-p", "-t", @session_name ]))
        raise "tmux capture-pane failed: #{err.empty? ? out : err}" unless status.success?

        out
      end

      # Waits for a TUI-dispatched workflow child to complete. Headless verbs run
      # through Subprocess.dispatch_background, so the foreground tmux pane remains
      # the long-lived `hive tui` process; tmux's pane_dead would wait for the
      # wrong lifecycle. The TUI writes BEGIN/END/ERRNO markers to a run-scoped
      # log, and step_tui_keys records the file offset immediately before sending
      # the dispatch key.
      def wait_for_subprocess_exit(timeout: 30.0, interval: 0.1)
        start
        return wait_for_subprocess_log(timeout: timeout, interval: interval) if @subprocess_log_path

        wait_for_pane_dead(timeout: timeout, interval: interval)
      end

      def wait_for_subprocess_log(timeout:, interval:)
        started_at = monotonic_time
        begin_id = nil
        loop do
          marker = subprocess_log_since_marker
          # Bind to the FIRST BEGIN that appears after the offset captured
          # by mark_subprocess_log!. The dispatched subprocess always emits
          # BEGIN[<id>] before any END or ERRNO, so a missing id means the
          # subprocess hasn't started yet — keep polling.
          begin_id ||= marker.match(/BEGIN(?:\([^)]+\))?\[([0-9a-f]{8})\]/)&.captures&.first
          if begin_id
            end_match = marker.match(/END(?:\([^)]+\))?\[#{begin_id}\] exit=(-?\d+)/)
            if end_match
              exit_code = end_match[1].to_i
              return :ok if exit_code.zero?

              raise SubprocessFailed.new(begin_id: begin_id, exit_code: exit_code, log: marker)
            end
          end
          # ERRNO entries don't carry an id (see lib/hive/tui/subprocess.rb)
          # — they signal an abnormal failure that never reaches END. Treat
          # any ERRNO appearing in the watched window as a subprocess crash.
          if marker.match?(/^----- [^\n]* ERRNO\b/)
            raise SubprocessAbnormal.new(begin_id: begin_id, log: marker)
          end

          elapsed = monotonic_time - started_at
          if elapsed >= timeout
            raise AnchorTimeout.new(
              anchor: "tui subprocess END[#{begin_id || '?'}]",
              captured: marker,
              elapsed: elapsed
            )
          end

          sleep interval
        end
      end

      def wait_for_pane_dead(timeout:, interval:)
        started_at = monotonic_time
        loop do
          out, err, status = capture_command(*(base_args + [
            "list-panes", "-t", @session_name, "-F", "\#{pane_dead}"
          ]))
          raise "tmux list-panes failed: #{err.empty? ? out : err}" unless status.success?
          return :ok if out.lines.first.to_s.strip == "1"

          elapsed = monotonic_time - started_at
          raise AnchorTimeout.new(anchor: "pane_dead", captured: out, elapsed: elapsed) if elapsed >= timeout

          sleep interval
        end
      end

      def cleanup
        capture_command(*(base_args + [ "kill-server" ]))
        @started = false
      rescue Errno::ENOENT
        nil
      end

      private

      def command_with_env
        return @command if @env.empty?

        Shellwords.join([ "env", *@env.map { |key, value| "#{key}=#{value}" } ]) + " #{@command}"
      end

      def subprocess_log_size
        return 0 unless @subprocess_log_path && File.exist?(@subprocess_log_path)

        File.size(@subprocess_log_path)
      end

      def subprocess_log_since_marker
        return "" unless @subprocess_log_path && File.exist?(@subprocess_log_path)

        @subprocess_log_offset = 0 if File.size(@subprocess_log_path) < @subprocess_log_offset.to_i
        File.open(@subprocess_log_path, "r") do |file|
          file.seek([ @subprocess_log_offset.to_i, 0 ].max)
          file.read
        end
      rescue Errno::EINVAL
        @subprocess_log_offset = 0
        File.read(@subprocess_log_path)
      end

      def base_args
        [ "tmux", "-L", @socket_name ]
      end

      def ensure_live!
        _out, _err, status = capture_command(*(base_args + [ "has-session", "-t", @session_name ]))
        return if status.success?

        raise DeadSession, "tmux session #{@session_name} is not running on #{@socket_name}"
      end

      def capture_command(*cmd, timeout: TMUX_COMMAND_TIMEOUT)
        started = monotonic_time
        Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_reader = Thread.new { read_stream(stdout) }
          err_reader = Thread.new { read_stream(stderr) }
          loop do
            if wait_thr.join(0.05)
              return [ out_reader.value, err_reader.value, wait_thr.value ]
            end

            elapsed = monotonic_time - started
            next if elapsed < timeout

            terminate_process_group(wait_thr.pid)
            raise TmuxCommandTimeout.new(stdout: safe_thread_value(out_reader), stderr: safe_thread_value(err_reader),
                                         elapsed: elapsed)
          end
        end
      end

      def read_stream(stream)
        stream.read
      rescue IOError
        ""
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      ensure
        sleep 0.1
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def safe_thread_value(thread)
        thread.kill if thread.alive?
        thread.value.to_s
      rescue StandardError
        ""
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
