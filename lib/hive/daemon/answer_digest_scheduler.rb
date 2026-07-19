require "hive/daemon/digest_scheduler_base"
require "hive/paths"

module Hive
  module Daemon
    class AnswerDigestScheduler < DigestSchedulerBase
      ANSWER_DIGEST_STAGE = "answer_digest".freeze
      ANSWER_DIGEST_PROJECT = "answer_digest".freeze
      DEFAULT_HOUR = 9
      FAILURE_BACKOFF_SCHEDULE = DigestSchedulerBase::FAILURE_BACKOFF_SCHEDULE
      SCHEDULER_CONTRACT = {
        project: ANSWER_DIGEST_PROJECT,
        stage: ANSWER_DIGEST_STAGE,
        command: "hive answer-digest",
        failure_event: :answer_digest_failure_backoff,
        state_unreadable_event: :answer_digest_state_unreadable
      }.freeze

      def initialize(state_path: nil, clock: -> { Time.now }, enabled: false,
                     hour: DEFAULT_HOUR, logger: nil)
        super(
          state_path: state_path || File.join(Hive::Paths.state_home, "answer_digest_state.json"),
          clock: clock, enabled: enabled, logger: logger
        )
        @hour = clamp_hour(hour)
      end

      def reconfigure(enabled:, hour:)
        @enabled = enabled == true
        @hour = clamp_hour(hour)
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any?
        return [] if backed_off?(now)
        return [] if now.getlocal.hour < @hour

        today = Hive::Digest::Window.local_today(now: now)
        state = read_state
        last = parse_date(state["last_fired_date"])
        return [] if last && last >= today

        @pending[today.iso8601] = true
        [ dispatch_for(today) ]
      end

      def complete(date:, exit_code:, now: @clock.call)
        local_date = Hive::Digest::Window.parse_date(date)
        @pending.delete(local_date.iso8601)

        # ChildSupervisor reports a nil exit status for a signalled child
        # (killed by SIGTERM/SIGKILL on shutdown or timeout). `nil.to_i` is 0,
        # so a bare `exit_code.to_i.zero?` would treat a killed digest as a
        # success and silently advance the cursor past that date. Treat a nil
        # (signalled / unknown) exit as a failure so the day is retried.
        # (Rationale carried verbatim from DigestScheduler#complete, the
        # deliberate mirror.)
        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end

        state = read_state
        last = parse_date(state["last_fired_date"])
        if last && last >= local_date
          # The cursor already covers this date (a stale/older completion); the
          # send is durably recorded, so clear any backoff and stop.
          @failure = nil
          return
        end

        # Advance the cursor FIRST and clear the failure backoff only once the
        # write durably lands. Clearing `@failure` before persisting would let a
        # write_state fault (ENOSPC/EROFS on the atomic rename) leave the day
        # owed with NO backoff, so the next tick re-fires and re-sends the same
        # daily Telegram digest in an unbounded loop. On a write failure we
        # instead (re-)engage the bounded backoff and re-raise so the dispatcher
        # logs it; the day stays owed and is retried on the backoff schedule.
        write_state("last_fired_date" => local_date.iso8601, "updated_at" => now.utc.iso8601)
        @failure = nil
      rescue StandardError
        record_failure(now)
        raise
      end

      private

      def clamp_hour(hour)
        [ [ hour.to_i, 0 ].max, 23 ].min
      end

      def parse_date(value)
        value && Date.iso8601(value.to_s)
      rescue ArgumentError => e
        # read_state only logs JSON/IO faults; a well-formed-JSON-but-malformed
        # `last_fired_date` would otherwise self-heal to nil in the dark. Log
        # it on the same event so a corrupt cursor is observable.
        log_state_unreadable("malformed last_fired_date #{value.inspect}: #{e.message}")
        nil
      end

      def scheduler_contract
        SCHEDULER_CONTRACT
      end
    end
  end
end
