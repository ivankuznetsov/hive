module Hive
  module Web
    # Process-wide cap on concurrently-open Server-Sent-Events streams. Each
    # `/events` and `/tasks/:project/:slug/logs` connection pins a Puma worker
    # thread for its whole lifetime; native `EventSource` holds one open per
    # browser tab and auto-reconnects, so without a ceiling a handful of open
    # dashboards can consume every thread and starve the auth gate itself.
    # `acquire` returns false once `max` streams are live; the route then
    # rejects with 503 instead of parking a thread it cannot spare.
    class SseLimiter
      def initialize(max:)
        @max = max
        @count = 0
        @mutex = Mutex.new
      end

      def acquire
        @mutex.synchronize do
          return false if @count >= @max

          @count += 1
          true
        end
      end

      def release
        @mutex.synchronize { @count -= 1 if @count.positive? }
      end
    end
  end
end
