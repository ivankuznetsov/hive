require "time"
require "tzinfo"
require "hive/daemon/digest_scheduler_base"
require "hive/daily_digest/store"
require "hive/paths"

module Hive
  module Daemon
    # Opt-in recap scheduler. It walks the persisted interval sequence and
    # targets the immediately preceding closed record; label arithmetic would
    # be wrong after an east/west/date-line zone cutover.
    class DailyDigestDeliveryScheduler < DigestSchedulerBase
      STAGE = "daily_digest_delivery".freeze
      PROJECT = "daily_digest_delivery".freeze
      DEFAULT_HOUR = 9
      SCHEDULER_CONTRACT = {
        project: PROJECT,
        stage: STAGE,
        command: "hive digest send",
        failure_event: :daily_digest_delivery_failure_backoff,
        state_unreadable_event: :daily_digest_delivery_state_unreadable
      }.freeze

      def initialize(state_path: nil, clock: -> { Time.now.utc }, enabled: false,
                     hour: DEFAULT_HOUR, logger: nil,
                     store: Hive::DailyDigest::Store.new)
        super(
          state_path: state_path || File.join(
            Hive::Paths.state_home, "daily_digest_delivery_state.json"
          ),
          clock: clock, enabled: enabled, logger: logger
        )
        @hour = valid_hour(hour)
        @store = store
        @pending_records = {}
      end

      def reconfigure(enabled:, hour:)
        @enabled = enabled == true
        @hour = valid_hour(hour)
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any? || backed_off?(now)

        target = preceding_closed_record(now)
        return [] unless target
        return [] unless due?(now, target.fetch(:current_interval))

        record = target.fetch(:record)
        state = read_state
        return [] if state["last_record_id"] == record.fetch("record_id")

        date = record.fetch("local_date")
        @pending[date] = true
        @pending_records[date] = record.fetch("record_id")
        [ dispatch_for(Date.iso8601(date)) ]
      end

      def cancel(date:)
        key = digest_date(date)
        @pending_records.delete(key)
        super
      end

      def complete(date:, exit_code:, envelope: nil, now: @clock.call, stage: nil)
        local_date = digest_date(date)
        record_id = @pending_records.delete(local_date) || record_id_for(local_date)
        @pending.delete(local_date)
        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end

        write_state(
          "last_fired_date" => local_date,
          "last_record_id" => record_id,
          "last_outcome" => envelope&.fetch("outcome", nil),
          "updated_at" => now.utc.iso8601(6)
        )
        @failure = nil
      rescue StandardError
        record_failure(now)
        raise
      end

      private

      def preceding_closed_record(now)
        instant = now.utc
        intervals = @store.intervals
        current_index = intervals.index do |interval|
          utc(interval.fetch("starts_at")) <= instant && instant < utc(interval.fetch("ends_at"))
        end
        return nil unless current_index&.positive?

        current = intervals.fetch(current_index)
        previous = intervals.fetch(current_index - 1)
        record = @store.read(previous.fetch("local_date"))
        return nil unless record.fetch("lifecycle") == "closed"

        { current_interval: current, record: record }
      rescue Hive::DailyDigest::MissingRecord
        nil
      end

      def due?(now, interval)
        zone = TZInfo::Timezone.get(interval.fetch("time_zone"))
        zone.utc_to_local(now.utc).hour >= @hour
      rescue TZInfo::InvalidTimezoneIdentifier
        false
      end

      def record_id_for(date)
        record = @store.read(date)
        return record.fetch("record_id") if record.fetch("lifecycle") == "closed"

        nil
      rescue Hive::DailyDigest::Error
        nil
      end

      def valid_hour(value)
        hour = Integer(value)
        return hour if hour.between?(0, 23)

        raise ArgumentError
      rescue ArgumentError, TypeError
        raise ArgumentError, "daily digest delivery hour must be an integer between 0 and 23"
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end

      def scheduler_contract = SCHEDULER_CONTRACT
    end
  end
end
