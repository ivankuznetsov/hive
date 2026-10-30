# frozen_string_literal: true

module Hive
  module RuntimeControlPlane
    # Invocation-local SQLite waiting, shared across runtime connections. Time
    # outside the busy callback (including startup and SQL work) is not charged.
    class ContentionBudget
      THREAD_KEY = :hive_runtime_contention_budget
      STATUS_SECONDS = 1.0
      RETRY_SECONDS = 0.01

      def self.current
        context = Thread.current[THREAD_KEY]
        context if context&.owner_pid == Process.pid
      end

      def self.with(**options)
        return yield current if current

        budget = new(**options)
        Thread.current[THREAD_KEY] = budget
        begin
          yield budget
        ensure
          budget.close
          Thread.current[THREAD_KEY] = nil
        end
      end

      attr_reader :owner_pid, :waited

      def initialize(seconds: STATUS_SECONDS,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     wait: ->(seconds) { sleep seconds })
        @remaining = Float(seconds)
        @clock = clock
        @wait = wait
        @waited = 0.0
        @owner_pid = Process.pid
        @connections = {}
      end

      def retry_busy
        return false if @remaining <= 0

        started = @clock.call
        @wait.call([@remaining, RETRY_SECONDS].min)
        elapsed = [@clock.call - started, 0.0].max
        @waited += elapsed
        @remaining = [@remaining - elapsed, 0.0].max
        @remaining > 0
      end

      def install(connection, restore_timeout_ms: nil)
        return if connection.closed?

        @connections[connection] ||= restore_timeout_ms ||
          connection.get_first_value("PRAGMA busy_timeout")
        connection.busy_handler { |_count| retry_busy }
      end

      def close
        @connections.each do |connection, timeout|
          connection.busy_timeout(timeout) unless connection.closed?
        end
      ensure
        @connections.clear
      end
    end
  end
end
