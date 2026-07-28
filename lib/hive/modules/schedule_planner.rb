require "time"
require "hive/cron_schedule"

module Hive
  module Modules
    ScheduleOccurrence = Data.define(:due_at, :missed_windows)

    # Small, dependency-free five-field UTC cron matcher. Module manifests
    # already reject non-five-field expressions; this layer validates each
    # field's numeric domain and coalesces any downtime to the latest due slot.
    class SchedulePlanner
      MAX_SCAN_MINUTES = 366 * 24 * 60

      def due(schedule:, after:, now:)
        finish = floor_minute(now)
        start = after ? floor_minute(after) : finish - 60
        return nil if finish <= start
        minutes = [ ((finish - start) / 60).to_i, MAX_SCAN_MINUTES ].min
        matches = []
        minutes.times do |offset|
          candidate = finish - (offset * 60)
          break if candidate <= start
          matches << candidate if match?(schedule, candidate)
        end
        return nil if matches.empty?

        ScheduleOccurrence.new(due_at: matches.max, missed_windows: [ matches.length - 1, 0 ].max)
      end

      def match?(schedule, time)
        Hive::CronSchedule.match?(schedule, time)
      end

      def next_after(schedule:, now:)
        cursor = floor_minute(now) + 60
        MAX_SCAN_MINUTES.times do |offset|
          candidate = cursor + (offset * 60)
          return candidate if match?(schedule, candidate)
        end
        nil
      end

      private

      def floor_minute(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        Time.utc(time.year, time.month, time.day, time.hour, time.min)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module schedule timestamp is malformed"
      end
    end
  end
end
