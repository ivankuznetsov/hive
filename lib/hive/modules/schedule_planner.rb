require "time"

module Hive
  module Modules
    ScheduleOccurrence = Data.define(:due_at, :missed_windows)

    # Small, dependency-free five-field UTC cron matcher. Module manifests
    # already reject non-five-field expressions; this layer validates each
    # field's numeric domain and coalesces any downtime to the latest due slot.
    class SchedulePlanner
      RANGES = [ 0..59, 0..23, 1..31, 1..12, 0..6 ].freeze
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
        fields = schedule.to_s.split
        raise Hive::ConfigError, "module schedule must contain five cron fields" unless fields.length == 5
        values = [ time.min, time.hour, time.day, time.month, time.wday ]
        fields.each_with_index.all? { |field, index| field_match?(field, values.fetch(index), RANGES.fetch(index)) }
      end

      private

      def field_match?(field, value, range)
        field.split(",").any? do |part|
          base, step = part.split("/", 2)
          step = step ? Integer(step, 10) : 1
          raise Hive::ConfigError, "module schedule step must be positive" unless step.positive?
          selected = if base == "*"
            range
          elsif base.include?("-")
            first, last = base.split("-", 2).map { |item| Integer(item, 10) }
            first..last
          else
            number = Integer(base, 10)
            number..number
          end
          unless range.cover?(selected.begin) && range.cover?(selected.end) && selected.begin <= selected.end
            raise Hive::ConfigError, "module schedule field is outside its allowed range"
          end
          selected.cover?(value) && ((value - selected.begin) % step).zero?
        end
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module schedule field is malformed"
      end

      def floor_minute(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        Time.utc(time.year, time.month, time.day, time.hour, time.min)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module schedule timestamp is malformed"
      end
    end
  end
end
