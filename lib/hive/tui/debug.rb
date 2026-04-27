require "fileutils"
require "tmpdir"
require "time"

module Hive
  module Tui
    # Opt-in debug logger for the TUI. When `HIVE_TUI_DEBUG=1` is set
    # in the environment, every instrumented site appends one line per
    # event to a tmpdir log file. Disabled by default so no
    # observability tax in production. Writes are line-buffered (sync
    # = true) so the log captures state immediately before any curses
    # call that could hang or corrupt the screen.
    #
    # The constant `ENABLED` snapshots the env var at load time; this
    # is intentional — toggling it later doesn't reach the running
    # process. Run `HIVE_TUI_DEBUG=1 hive tui` to start a logged
    # session, then `tail -f /tmp/hive-tui-debug.log` in a sibling
    # shell.
    module Debug
      ENABLED = !ENV["HIVE_TUI_DEBUG"].to_s.strip.empty?
      LOG_PATH = File.join(Dir.tmpdir, "hive-tui-debug.log")

      @file = nil
      @mutex = Mutex.new

      module_function

      def log(tag, message = nil)
        return unless ENABLED

        line = format_line(tag, message)
        @mutex.synchronize do
          @file ||= open_log
          @file.puts(line)
        end
      rescue StandardError
        # Logging must never crash the TUI. Swallow file/IO errors;
        # the user invoked debug mode and at worst gets fewer lines.
        nil
      end

      # Convenience for instrumenting a block: logs entry + exit + any
      # exception, returning the block's value. Use sparingly — adds
      # one log line each side of the wrapped call.
      def around(tag, message = nil)
        log(tag, "enter #{message}".rstrip)
        result = yield
        log(tag, "exit  #{message} -> #{result.inspect}".rstrip)
        result
      rescue StandardError => e
        log(tag, "raise #{message} -> #{e.class}: #{e.message}".rstrip)
        raise
      end

      def log_path
        ENABLED ? LOG_PATH : nil
      end

      def format_line(tag, message)
        ts = Time.now.utc.strftime("%H:%M:%S.%3N")
        if message.nil? || message.to_s.empty?
          "#{ts} [#{tag}]"
        else
          "#{ts} [#{tag}] #{message}"
        end
      end

      def open_log
        f = File.open(LOG_PATH, "a")
        f.sync = true
        f.puts "=== hive tui debug session pid=#{Process.pid} started #{Time.now.utc.iso8601} ==="
        f
      end
    end
  end
end
