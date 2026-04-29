require "fileutils"
require "hive"
require "hive/tui/debug"

module Hive
  module Tui
    # Headless filesystem layer for the TUI's `agent_running`
    # log-viewer mode. Two collaborators:
    #
    #   - `FileResolver` picks the most recent `*.log` under a task's
    #     log directory by mtime. Pure data; no I/O at construction;
    #     unit-tested.
    #   - `Tail` keeps a non-blocking read cursor on one open log file
    #     plus a bounded ring buffer of the last N lines so the render
    #     layer can paint a frame without blocking on disk I/O.
    #
    # Both pieces deliberately avoid threads — `BubbleModel#open_log_tail`
    # calls `Tail#poll!` per render to ingest any new bytes since the
    # last frame. The Bubble Tea runner's input poll handles user
    # keystrokes on the same loop, so the buffer stays fresh without
    # the synchronisation footprint of a worker thread.
    module LogTail
      module FileResolver
        module_function

        # Returns the path with the most recent mtime among
        # `<log_dir>/*.log`. Raises `Hive::NoLogFiles` when the glob
        # is empty so the render-mode boundary can short-circuit
        # back to grid with a flash message instead of opening an
        # empty viewer.
        def latest(log_dir)
          candidates = Dir[File.join(log_dir, "*.log")]
          raise Hive::NoLogFiles, "no log files in #{log_dir}" if candidates.empty?

          # `File.mtime` can race with concurrent log rotation that removes a
          # path between glob and stat; skip the vanished entries rather than
          # let Errno::ENOENT crash the TUI.
          with_mtimes = candidates.filter_map do |path|
            [ path, File.mtime(path) ]
          rescue Errno::ENOENT
            nil
          end
          raise Hive::NoLogFiles, "no log files in #{log_dir}" if with_mtimes.empty?

          with_mtimes.max_by(&:last).first
        end
      end

      # Open one log file, hold a bounded line buffer, and incrementally
      # absorb appends via non-blocking reads. `open!` primes the buffer
      # from a backbuffer-bytes window at the tail of the file so the
      # first paint shows recent context immediately. `poll!` is
      # idempotent and safe to call every render frame.
      class Tail
        DEFAULT_RING_CAPACITY = 2000
        DEFAULT_BACKBUFFER_BYTES = 64 * 1024
        READ_CHUNK = 8192

        # Cap on the unterminated partial line. The completed-line
        # buffer is bounded by `@ring_capacity`, but `@partial`
        # accumulates everything between newlines — a child writing a
        # huge no-newline blob would otherwise grow this without limit.
        # 16KB is generous for any realistic log line; oversize prefixes
        # are flushed as a synthetic line so the user still sees fresh
        # bytes instead of a frozen view.
        PARTIAL_BYTE_CAP = 16 * 1024

        attr_reader :path

        def initialize(path, ring_capacity: DEFAULT_RING_CAPACITY,
                       backbuffer_bytes: DEFAULT_BACKBUFFER_BYTES)
          @path = path
          @ring_capacity = ring_capacity
          @backbuffer_bytes = backbuffer_bytes
          @buffer = []
          @partial = +""
          @inode = nil
          @file = nil
        end

        # Explicit open so test code can probe initial state before any
        # IO. Seeks to the last `@backbuffer_bytes` so a long log
        # doesn't dump megabytes through the renderer at startup;
        # records the inode so `poll!` can detect rotation cheaply.
        def open!
          @file = File.open(@path, "r")
          size = @file.size
          start = [ size - @backbuffer_bytes, 0 ].max
          @file.seek(start)
          # Drop bytes until the next newline so we never display a
          # half-line. When the seek lands ON a newline boundary,
          # `gets` consumes only the empty/whitespace remainder of
          # that line (zero bytes if start was an exact boundary), so
          # we don't lose a whole line the way an unconditional shift
          # would.
          @file.gets if start.positive?
          chunk = @file.read
          ingest(chunk) if chunk
          @inode = File.stat(@path).ino
          self
        end

        # Idempotent non-blocking drain. Branches:
        #   - inode at @path differs from cached inode → file rotated
        #     out from under us; close and re-open the new inode from
        #     position 0.
        #   - file size shrank below current position → truncation;
        #     reset to position 0 and clear partial-line buffer.
        #     The line buffer is intentionally preserved so the user
        #     keeps seeing the last good frame instead of a blank
        #     screen flash; new appends overlay it organically.
        #   - else → read_nonblock until EOFError; emit complete lines.
        def poll!
          return unless @file

          handle_rotation_if_needed
          handle_truncation_if_needed
          drain_nonblocking
        rescue Errno::ESPIPE
          # Pipe-like rewind/seek error — reopen the resolved file from
          # scratch. Other Errno::* are swallowed so the renderer keeps
          # painting cached state instead of crashing.
          reopen
        rescue Errno::ENOENT, Errno::EACCES, Errno::EBADF, Errno::EIO => e
          # Transient filesystem trouble; leave buffer intact and try
          # again on the next poll. Logged so an EBADF (FD closed
          # behind our back — view freezes until reopen) can be
          # diagnosed via `HIVE_TUI_DEBUG=1` instead of looking like
          # a hang.
          Hive::Tui::Debug.log("log_tail", "poll! errno=#{e.class.name.split('::').last}")
          nil
        end

        # Last `count` lines from the buffer, oldest first. Renderer
        # asks for `terminal_height - 2` so the count maps to drawable
        # rows rather than absolute buffer size. When a final partial
        # (no-newline) line is buffered, surface it as the last entry
        # so live writes from a still-running agent surface in the
        # tail before the line terminator arrives.
        def lines(count)
          return [] if count <= 0

          if @partial.empty?
            @buffer.last(count)
          else
            @buffer.last([ count - 1, 0 ].max) + [ @partial.dup ]
          end
        end

        def close!
          @file&.close
        rescue IOError => e
          Hive::Tui::Debug.log("log_tail", "close! IOError: #{e.message}")
          nil
        ensure
          @file = nil
        end

        private

        def handle_rotation_if_needed
          current_ino = File.stat(@path).ino
          return if current_ino == @inode

          reopen
        end

        def handle_truncation_if_needed
          return unless @file

          pos = @file.pos
          size = File.size(@path)
          return unless size < pos

          @file.rewind
          @partial = +""
        end

        def drain_nonblocking
          loop do
            chunk = @file.read_nonblock(READ_CHUNK)
            ingest(chunk)
          end
        rescue EOFError, IO::WaitReadable
          nil
        end

        def reopen
          @file&.close
          @file = File.open(@path, "r")
          @inode = File.stat(@path).ino
          @partial = +""
          # Keep prior @buffer so the user sees the old tail until new
          # bytes overwrite it; reading from offset 0 of a freshly-
          # rotated file would otherwise dump a fresh banner over a
          # currently-readable view.
        end

        def ingest(chunk)
          @partial << chunk
          while (newline_at = @partial.index("\n"))
            line = @partial.slice!(0, newline_at + 1)
            line = line.chomp
            line = line.chomp("\r")
            @buffer << line
          end
          flush_oversized_partial!
          trim_buffer
        end

        # Cap memory growth from a no-newline child. While @partial
        # exceeds PARTIAL_BYTE_CAP, flush the prefix as a single
        # synthetic line and keep the suffix; loop until the cap holds
        # so a single oversized ingest (e.g., Tail#open!'s 64KiB
        # backbuffer read in one call) can't park a multi-cap partial
        # in memory after one flush. Drops nothing — bytes are split
        # arbitrarily on byte boundary across multiple synthetic lines.
        def flush_oversized_partial!
          while @partial.bytesize > PARTIAL_BYTE_CAP
            prefix = @partial.byteslice(0, PARTIAL_BYTE_CAP)
            suffix = @partial.byteslice(PARTIAL_BYTE_CAP, @partial.bytesize - PARTIAL_BYTE_CAP)
            @buffer << prefix
            @partial = +(suffix.to_s)
          end
        end

        def trim_buffer
          return if @buffer.size <= @ring_capacity

          @buffer.shift(@buffer.size - @ring_capacity)
        end
      end
    end
  end
end
