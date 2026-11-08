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
      REFRESH_STAGE = "daily_digest_refresh".freeze
      PROJECT = "daily_digest".freeze
      SCHEDULER_CONTRACT = {
        project: PROJECT,
        stage: STAGE,
        command: "hive digest refresh",
        failure_event: :daily_digest_scheduler_failure_backoff,
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
        pending_for(REFRESH_STAGE)
        pending_for(STAGE)
      end

      def reconfigure(enabled:, interval_sec:)
        @enabled = enabled == true
        @interval_sec = positive_interval(interval_sec)
      end

      def tick(now: @clock.call)
        return [] unless @enabled

        date = digest_date(@date_resolver.call(now))
        stage = stage_for(date, now: now)
        return [] if pending_for(stage).any? || stage_backed_off?(stage, now)

        state = read_state
        last = parse_time(state[state_time_key(stage)] || state["last_completed_at"])
        return [] if last && now.utc - last < @interval_sec

        pending_for(stage)[date] = true
        [ dispatch_for(date, stage: stage) ]
      end

      def complete(date:, exit_code:, envelope: nil, now: @clock.call, stage: nil)
        local_date = digest_date(date)
        stage = completion_stage(local_date, stage, now: now)
        pending_for(stage).delete(local_date)
        unless exit_code && exit_code.to_i.zero?
          record_stage_failure(stage, now)
          return
        end

        state = read_state.merge(
          state_time_key(stage) => now.utc.iso8601(6),
          state_date_key(stage) => local_date,
          "updated_at" => now.utc.iso8601(6)
        )
        write_state(state)
        clear_stage_failure(stage)
      rescue StandardError
        record_stage_failure(stage || STAGE, now)
        raise
      end

      private

      def dispatch_for(date, stage: STAGE)
        {
          project: stage, slug: date.to_s, stage: stage,
          command: "hive digest refresh --json",
          state_file_mtime: nil, state_file_path: nil, hive_state_path: nil
        }
      end

      def stage_for(date, now:)
        record = @store.read(date)
        return REFRESH_STAGE if record.fetch("lifecycle") == "open" &&
                                now.utc < Time.iso8601(record.fetch("ends_at"))

        STAGE
      rescue Hive::DailyDigest::Error
        STAGE
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

      def normalize_stage(stage)
        value = stage.to_s
        return value if [ REFRESH_STAGE, STAGE ].include?(value)

        raise ArgumentError, "unknown daily digest scheduler stage #{stage.inspect}"
      end

      def completion_stage(date, explicit, now:)
        return normalize_stage(explicit) if explicit

        matches = @pending.filter_map { |identity, dates| identity if dates.key?(date) }
        return matches.first if matches.one?
        return stage_for(date, now: now) if matches.empty?

        raise ArgumentError, "daily digest completion stage is ambiguous for #{date}"
      end

      def state_time_key(stage)
        stage == REFRESH_STAGE ? "last_refresh_completed_at" : "last_close_completed_at"
      end

      def state_date_key(stage)
        stage == REFRESH_STAGE ? "last_refresh_record_date" : "last_close_record_date"
      end

      def positive_interval(value)
        number = Integer(value)
        raise ArgumentError unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise ArgumentError, "daily digest materialization interval must be a positive integer"
      end

      def scheduler_contract = SCHEDULER_CONTRACT

      def stage_identity(stage) = normalize_stage(stage || STAGE)
    end
  end
end
