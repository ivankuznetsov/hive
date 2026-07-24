require "hive/daemon/digest_scheduler_base"
require "hive/london_date"
require "hive/paths"

module Hive
  module Daemon
    class DigestScheduler < DigestSchedulerBase
      DIGEST_STAGE = "digest".freeze
      DIGEST_PROJECT = "digest".freeze
      DEFAULT_MAX_CATCHUP_DAYS = 7
      # Escalating backoff (seconds) after a non-zero digest exit, mirroring
      # the patrol/merge-watcher failure schedules. Without it a date that
      # keeps failing re-dispatches a paid categorizer agent every poll.
      FAILURE_BACKOFF_SCHEDULE = DigestSchedulerBase::FAILURE_BACKOFF_SCHEDULE
      SCHEDULER_CONTRACT = {
        project: DIGEST_PROJECT,
        stage: DIGEST_STAGE,
        command: "hive digest",
        failure_event: :digest_failure_backoff,
        state_unreadable_event: :digest_state_unreadable
      }.freeze

      def initialize(state_path: nil, clock: -> { Time.now }, enabled: false,
                     max_catchup_days: DEFAULT_MAX_CATCHUP_DAYS, logger: nil)
        super(
          state_path: state_path || File.join(Hive::Paths.state_home, "digest_state.json"),
          clock: clock, enabled: enabled, logger: logger
        )
        @max_catchup_days = [ max_catchup_days.to_i, 0 ].max
      end

      # Apply a SIGHUP config reload in place so an operator enabling the
      # digest (or retuning the catch-up cap) takes effect within one tick,
      # without dropping the in-memory pending/backoff state a rebuild would
      # lose. Mirrors the daemon's "takes effect within one tick" contract.
      def reconfigure(enabled:, max_catchup_days:)
        @enabled = enabled == true
        @max_catchup_days = [ max_catchup_days.to_i, 0 ].max
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any?
        return [] if backed_off?(now)

        today = Hive::LondonDate.today(now: now)
        completed_day = today - 1
        state = read_state
        last = parse_date(state["last_digested_date"])

        unless last
          write_state("last_digested_date" => completed_day.iso8601)
          return []
        end

        owed = owed_days(last, completed_day)
        return [] if owed.empty?
        blocked = parse_date(state["blocked_date"])
        return [] if blocked == owed.first

        # apply_catchup_cap returns `owed` unchanged or its non-empty tail
        # (max_catchup_days >= 1 on the capping branch), so the post-cap result
        # is always non-empty here — no second emptiness guard is reachable.
        owed = apply_catchup_cap(owed)

        date = owed.first
        @pending[date.iso8601] = true
        [ dispatch_for(date) ]
      end

      def complete(date:, exit_code:, envelope: nil, now: @clock.call)
        local_date = Hive::LondonDate.parse(date)
        @pending.delete(local_date.iso8601)
        if permanent_delivery_failure?(exit_code, envelope)
          park_permanent_failure(local_date, envelope, now)
          return
        end

        # ChildSupervisor reports a nil exit status for a signalled child
        # (killed by SIGTERM/SIGKILL on shutdown or timeout). `nil.to_i` is
        # 0, so a bare `exit_code.to_i.zero?` would treat a killed digest as
        # a success and silently advance the cursor past that date. Treat a
        # nil (signalled / unknown) exit as a failure so the day is retried.
        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end

        state = read_state
        last = parse_date(state["last_digested_date"])
        if last && last >= local_date
          @failure = nil
          return
        end

        write_state("last_digested_date" => local_date.iso8601, "updated_at" => now.utc.iso8601)
        @failure = nil
      rescue StandardError
        record_failure(now)
        raise
      end

      private

      def owed_days(last, completed_day)
        return [] if last >= completed_day

        ((last + 1)..completed_day).to_a
      end

      def apply_catchup_cap(owed)
        return owed if @max_catchup_days.zero? || owed.size <= @max_catchup_days

        skipped = owed.first(owed.size - @max_catchup_days)
        last_skipped = skipped.last
        write_state("last_digested_date" => last_skipped.iso8601)
        @logger&.event(
          :digest_catchup_skipped,
          skipped_from: skipped.first.iso8601,
          skipped_to: last_skipped.iso8601,
          skipped_days: skipped.size,
          max_catchup_days: @max_catchup_days
        )
        owed.last(@max_catchup_days)
      end

      def parse_date(value)
        value && Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def permanent_delivery_failure?(exit_code, envelope)
        return false unless exit_code && !exit_code.to_i.zero?
        return false unless envelope.is_a?(Hash)

        %w[
          telegram_refused
          telegram_permanent
          telegram_ambiguous
          delivery_checkpoint_permanent
        ].include?(envelope.dig("error", "kind").to_s)
      end

      def park_permanent_failure(date, envelope, now)
        error = envelope.fetch("error")
        state = read_state.merge(
          "blocked_date" => date.iso8601,
          "blocked_error_kind" => error.fetch("kind"),
          "blocked_message" => error["message"].to_s,
          "blocked_at" => now.utc.iso8601
        )
        write_state(state)
        @failure = nil
        @logger&.event(
          :digest_permanent_failure,
          date: date.iso8601,
          error_kind: error.fetch("kind"),
          error: error["message"].to_s,
          delivery: envelope["delivery"]
        )
      end

      def scheduler_contract
        SCHEDULER_CONTRACT
      end
    end
  end
end
