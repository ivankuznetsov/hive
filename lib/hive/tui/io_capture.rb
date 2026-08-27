# frozen_string_literal: true

require "stringio"

module Hive
  module Tui
    # Suppresses `$stdout`/`$stderr` for the duration of a block without the
    # process-global save/restore race that plagued the previous per-caller
    # `orig = $stdout; $stdout = StringIO.new ... $stdout = orig` pattern.
    #
    # The old pattern assumed single-threaded nesting. It did not hold:
    # `StateSource#capture_status_io` runs on the short-lived archive
    # refresher thread while `BubbleModel#capture_command_io` runs on the
    # TUI update thread. When both overlapped, one block's `ensure` could
    # restore the other's throwaway StringIO as the "original" `$stdout`,
    # leaving every later write — including teardown — silently discarded.
    #
    # This module coordinates all captures through one mutex-guarded
    # registry. Only the FIRST capture under an empty registry records the
    # current bindings as the base and installs its buffers; only the LAST
    # capture out restores them. A capture entering while another thread's
    # capture is active never observes a transient buffer as "original",
    # and a capture exiting while others remain active hands the binding to
    # a still-live buffer instead of restoring anything. Output written
    # inside any active capture is discarded either way, which is the only
    # contract these suppression buffers ever had.
    module IoCapture
      MUTEX = Mutex.new
      ACTIVE = []

      class << self
        attr_accessor :base_out, :base_err
      end

      def self.capture
        raise ArgumentError, "IoCapture.capture requires a block" unless block_given?

        out_buffer = StringIO.new
        err_buffer = StringIO.new
        entry = { out_buffer:, err_buffer: }
        # Registration and installation happen under one lock hold: the
        # instant any capture is registered, the global bindings already
        # point at a live suppression buffer. Installing outside the lock
        # (as an earlier draft did) left a window where a second capture
        # could register, run its whole block, and write straight to the
        # real TTY because the first thread had not swapped yet.
        MUTEX.synchronize do
          if ACTIVE.empty?
            IoCapture.base_out = $stdout
            IoCapture.base_err = $stderr
            $stdout = out_buffer
            $stderr = err_buffer
          end
          ACTIVE.push(entry)
        end
        begin
          yield
        ensure
          MUTEX.synchronize do
            ACTIVE.delete(entry)
            if ACTIVE.empty?
              $stdout = IoCapture.base_out
              $stderr = IoCapture.base_err
              IoCapture.base_out = nil
              IoCapture.base_err = nil
            elsif $stdout.equal?(out_buffer)
              successor = ACTIVE.last
              $stdout = successor[:out_buffer]
              $stderr = successor[:err_buffer]
            end
          end
        end
      end
    end
  end
end
