require "time"
require "hive/config"
require "hive/daemon/digest_scheduler_base"
require "hive/daily_digest/calendar"
require "hive/daily_digest/store"
require "hive/paths"

module Hive
  module Daemon
    # Coalesced daemon owner for open-day refresh, chronological catch-up,
    # close, and gap recovery. Telegram delivery has a separate U6 scheduler.
    class DailyDigestCloseScheduler < DigestSchedulerBase
      STAGE = "daily_digest_close".freeze
      PROJECT = "daily_digest".freeze
      SCHEDULER_CONTRACT = {
        project: PROJECT,
        stage: STAGE,
        command: "hive digest refresh",
        failure_event: :daily_digest_close_failure_backoff,
        state_unreadable_event: :daily_digest_close_state_unreadable
      }.freeze

      def initialize(state_path: nil, clock: -> { Time.now.utc }, enabled: false,
                     interval_sec: 300, logger: nil, date_resolver: nil,
                     store: Hive::DailyDigest::Store.new,
                     config_loader: Hive::Config.method(:load_global_daily_digest))
        super(
          state_path: state_path || File.join(Hive::Paths.state_home, "daily_digest_close_state.json"),
          clock: clock, enabled: enabled, logger: logger
        )
        @interval_sec = positive_interval(interval_sec)
        @store = store
        @config_loader = config_loader
        @date_resolver = date_resolver || method(:resolve_date)
      end

      def reconfigure(enabled:, interval_sec:)
        @enabled = enabled == true
        @interval_sec = positive_interval(interval_sec)
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any? || backed_off?(now)

        state = read_state
        last = parse_time(state["last_completed_at"])
        return [] if last && now.utc - last < @interval_sec

        date = digest_date(@date_resolver.call(now))
        @pending[date] = true
        [ dispatch_for(date) ]
      end

      def complete(date:, exit_code:, envelope: nil, now: @clock.call)
        local_date = digest_date(date)
        @pending.delete(local_date)
        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end

        write_state(
          "last_completed_at" => now.utc.iso8601(6),
          "last_record_date" => local_date,
          "updated_at" => now.utc.iso8601(6)
        )
        @failure = nil
      rescue StandardError
        record_failure(now)
        raise
      end

      private

      def dispatch_for(date)
        {
          project: PROJECT, slug: date.to_s, stage: STAGE,
          command: "hive digest refresh --json",
          state_file_mtime: nil, state_file_path: nil, hive_state_path: nil
        }
      end

      def resolve_date(now)
        instant = now.utc
        persisted = @store.intervals.find do |interval|
          Time.iso8601(interval.fetch("starts_at")) <= instant &&
            instant < Time.iso8601(interval.fetch("ends_at"))
        end
        return persisted.fetch("local_date") if persisted

        config = @config_loader.call
        Hive::DailyDigest::Calendar.new(time_zone: config.fetch("time_zone"))
                                   .local_date_at(instant).iso8601
      end

      def parse_time(value)
        value && Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError => error
        log_state_unreadable("malformed last_completed_at #{value.inspect}: #{error.message}")
        nil
      end

      def positive_interval(value)
        number = Integer(value)
        raise ArgumentError unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise ArgumentError, "daily digest materialization interval must be a positive integer"
      end

      def scheduler_contract = SCHEDULER_CONTRACT
    end
  end
end
