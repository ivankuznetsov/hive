# frozen_string_literal: true

module Hive
  # Mutex-guarded monotonic instant of the most recent child-process output.
  # Pipe-reader threads touch it per chunk; a wait loop reads it to enforce an
  # idle-output deadline without any further coordination between threads.
  class OutputPulse
    def initialize
      @mutex = Mutex.new
      @at = monotonic
    end

    def touch
      now = monotonic
      @mutex.synchronize { @at = now }
    end

    def last
      @mutex.synchronize { @at }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
