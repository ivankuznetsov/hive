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

      attr_reader :socket_name, :session_name, :keystrokes

      def self.available?
        _out, _err, status = Open3.capture3("tmux", "-V")
        status.success?
      rescue Errno::ENOENT
        false
      end

      def initialize(run_id:, session_name:, command:, env: {}, rows: 50, cols: 200)
        @socket_name = "hive-e2e-#{run_id}"
        @session_name = session_name
        @command = command
        @env = env
        @rows = rows
        @cols = cols
        @keystrokes = []
        @started = false
      end

      def start
        return if @started

        args = base_args + [
          "new-session", "-d", "-P", "-F", "\#{session_id}",
          "-s", @session_name, "-x", @cols.to_s, "-y", @rows.to_s
        ]
        @env.each { |key, value| args.concat([ "-e", "#{key}=#{value}" ]) }
        args << @command
        out, err, status = Open3.capture3(*args)
        raise "tmux new-session failed: #{err.empty? ? out : err}" unless status.success?

        @tmux_session_id = out.strip
        @started = true
      end

      def send_keys(keys, literal: false)
        start
        args = base_args + [ "send-keys", "-t", @session_name ]
        args << "-l" if literal
        Array(keys).each { |key| args << key.to_s }
        out, err, status = Open3.capture3(*args)
        raise "tmux send-keys failed: #{err.empty? ? out : err}" unless status.success?

        @keystrokes << { "at" => Time.now.utc.iso8601, "keys" => Array(keys).map(&:to_s), "literal" => literal }
      end

      def send_text(text)
        text.to_s.each_char { |char| send_keys(char, literal: true) }
      end

      def capture_pane
        start
        ensure_live!
        out, err, status = Open3.capture3(*(base_args + [ "capture-pane", "-p", "-t", @session_name ]))
        raise "tmux capture-pane failed: #{err.empty? ? out : err}" unless status.success?

        out
      end

      # `require_stable: true` forces a second capture after a positive anchor
      # match before returning :ok. This avoids false positives where the anchor
      # text appears mid-render (e.g. between scroll lines while the TUI is still
      # writing) — without it we can hand back control to the next step before
      # the screen has actually settled.
      def wait_for(anchor: nil, timeout: 3.0, interval: 0.1, allow_stable: true, require_stable: true)
        start
        started_at = monotonic_time
        previous = nil
        stable_count = 0
        last = +""

        loop do
          ensure_live!
          last = capture_pane
          if anchor && last.include?(anchor)
            return :ok unless require_stable

            sleep interval
            confirm = capture_pane
            return :ok if confirm.include?(anchor) && confirm == last

            previous = confirm
            last = confirm
          end

          if allow_stable && !anchor.nil? && last == previous
            stable_count += 1
            return :ok if stable_count >= 2
          else
            stable_count = 0
          end
          previous = last

          elapsed = monotonic_time - started_at
          raise AnchorTimeout.new(anchor: anchor, captured: last, elapsed: elapsed) if elapsed >= timeout

          sleep interval
        end
      end

      # Waits for the subprocess running inside the tmux pane to exit. The previous
      # implementation polled for the running anchor "hive tui" which is present
      # *while* the TUI is alive — so it returned immediately. We now poll
      # `#{pane_dead}` (1 once the foreground process exits) which is the
      # authoritative tmux signal that the subprocess has completed.
      def wait_for_subprocess_exit(timeout: 30.0, interval: 0.1)
        start
        started_at = monotonic_time
        loop do
          out, err, status = Open3.capture3(*(base_args + [
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
        Open3.capture3(*(base_args + [ "kill-server" ]))
        @started = false
      rescue Errno::ENOENT
        nil
      end

      private

      def base_args
        [ "tmux", "-L", @socket_name ]
      end

      def ensure_live!
        _out, _err, status = Open3.capture3(*(base_args + [ "has-session", "-t", @session_name ]))
        return if status.success?

        raise DeadSession, "tmux session #{@session_name} is not running on #{@socket_name}"
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
