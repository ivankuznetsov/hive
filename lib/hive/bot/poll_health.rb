module Hive
  module Bot
    class PollHealth
      DEFAULT_MAX_CONSECUTIVE = 5
      DEFAULT_MAX_SILENCE_SEC = 60

      Result = Data.define(:escalate, :reason, :consecutive_failures, :seconds_since_success) do
        def escalate?
          escalate
        end
      end

      def initialize(now: -> { Time.now }, max_consecutive: DEFAULT_MAX_CONSECUTIVE,
                     max_silence_sec: DEFAULT_MAX_SILENCE_SEC)
        @now = now
        @max_consecutive = max_consecutive
        @max_silence_sec = max_silence_sec
        @last_success_at = @now.call
        @consecutive_failures = 0
        @unhealthy_latched = false
      end

      def record_success
        @consecutive_failures = 0
        @last_success_at = @now.call
        @unhealthy_latched = false
        nil
      end

      def record_failure
        @consecutive_failures += 1
        seconds_since_success = [ @now.call - @last_success_at, 0 ].max
        reason = unhealthy_reason(seconds_since_success)
        should_escalate = !reason.nil? && !@unhealthy_latched
        @unhealthy_latched = true if should_escalate

        Result.new(
          escalate: should_escalate,
          reason: should_escalate ? reason : nil,
          consecutive_failures: @consecutive_failures,
          seconds_since_success: seconds_since_success
        )
      end

      private

      def unhealthy_reason(seconds_since_success)
        return :consecutive if @consecutive_failures >= @max_consecutive
        return :silence if seconds_since_success >= @max_silence_sec

        nil
      end
    end
  end
end
