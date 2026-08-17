module Hive
  module TaskWorkspace
    # Shares one exact-usage read budget across every projection built for a
    # task request. Results (and failures) are memoized per durable attempt so
    # the compatibility v1 and semantic v2 views cannot independently rescan
    # the usage store.
    class BoundedUsageReader
      Failure = Data.define(:error)

      def self.wrap(reader, limits:, monotonic_clock: nil)
        return reader if reader.is_a?(self)

        new(reader: reader, limits: limits, monotonic_clock: monotonic_clock)
      end

      def initialize(reader:, limits:, monotonic_clock: nil)
        @reader = reader
        @limit = limits.fetch(:usage_sessions_per_attempt)
        @clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @deadline = @clock.call + limits.fetch(:usage_deadline_seconds)
        @cache = {}
      end

      def exact_attempt(attempt_id:, task_generation: nil, project_slug: nil,
                        task_slug: nil)
        key = [ attempt_id.to_s, task_generation, project_slug.to_s, task_slug.to_s ]
        cached = @cache[key]
        return unwrap(cached) if @cache.key?(key)
        return unavailable("deadline_exhausted") if deadline_exhausted?

        args = {
          attempt_id: attempt_id, task_generation: task_generation,
          project_slug: project_slug, task_slug: task_slug
        }
        callable = @reader.respond_to?(:exact_attempt) ?
          @reader.method(:exact_attempt) : @reader.method(:call)
        args[:session_limit] = @limit if accepts_keyword?(callable, :session_limit)
        if accepts_keyword?(callable, :deadline)
          args[:deadline] = @deadline
          args[:monotonic_clock] = @clock if accepts_keyword?(callable, :monotonic_clock)
        end

        @cache[key] = bound(callable.call(**args))
        unwrap(@cache.fetch(key))
      rescue StandardError => e
        @cache[key] = Failure.new(error: e) if key
        raise
      end

      alias call exact_attempt

      private

      def accepts_keyword?(callable, name)
        callable.parameters.any? do |kind, candidate|
          kind == :keyrest || (%i[key keyreq].include?(kind) && candidate == name)
        end
      end

      def bound(response)
        value = response.to_h.dup
        sessions_key = value.key?(:sessions) ? :sessions : "sessions"
        truncated_key = if value.key?(:truncated) || sessions_key == :sessions
          :truncated
        else
          "truncated"
        end
        sessions = Array(value[sessions_key])
        value[sessions_key] = sessions.first(@limit)
        value[truncated_key] = value[truncated_key] == true || sessions.length > @limit
        value
      end

      def deadline_exhausted?
        @clock.call >= @deadline
      end

      def unavailable(reason)
        {
          available: false, sessions: [], totals: nil,
          unattributed_count: nil, reason: reason
        }
      end

      def unwrap(value)
        raise value.error if value.is_a?(Failure)

        value
      end
    end
  end
end
