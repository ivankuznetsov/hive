module Hive
  module Bot
    class PollHealth
      DEFAULT_MAX_CONSECUTIVE = 5
      DEFAULT_MAX_SILENCE_SEC = 60

      # `reason` is the single source of truth: it is non-nil exactly when this
      # failure escalates a fresh unhealthy episode, so `escalate?` derives from
      # it. Dropping a separate `escalate` boolean makes the contradictory
      # `escalate: false, reason: :silence` state unrepresentable.
      #
      # `consecutive_failures` and `seconds_since_success` are only meaningful
      # on the escalation path (when `escalate?` is true): they exist to
      # populate the `poll_unhealthy` event. On a non-escalating failure they
      # still carry their raw counters, but no caller should read them — the
      # numbers describe an outage that isn't being reported.
      Result = Data.define(:reason, :consecutive_failures, :seconds_since_success) do
        def escalate?
          !reason.nil?
        end
      end

      def initialize(now: -> { Time.now }, max_consecutive: DEFAULT_MAX_CONSECUTIVE,
                     max_silence_sec: DEFAULT_MAX_SILENCE_SEC)
        @now = now
        @max_consecutive = max_consecutive
        @max_silence_sec = max_silence_sec
        # Seed the silence window to construction (bot start) time so the first
        # record_failure can't instantly read as a :silence outage.
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
        reason = nil unless should_escalate

        Result.new(
          reason: reason,
          consecutive_failures: @consecutive_failures,
          seconds_since_success: seconds_since_success.round
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
