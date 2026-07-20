require "date"
require "time"
require "tzinfo"

module Hive
  module Digest
    module LondonWindow
      ZONE = TZInfo::Timezone.get("Europe/London")

      module_function

      def local_today(now: Time.now)
        ZONE.to_local(parse_time(now).utc).to_date
      end

      def previous_day(now: Time.now)
        local_today(now: now) - 1
      end

      def on_date?(instant, date)
        start_at, end_at = utc_bounds(date)
        value = parse_time(instant).utc
        value >= start_at && value < end_at
      end

      def utc_bounds(date)
        value = parse_date(date)
        [ local_midnight_utc(value), local_midnight_utc(value + 1) ].freeze
      end

      def parse_date(date)
        return date if date.is_a?(Date)

        Date.iso8601(date.to_s)
      end

      def parse_time(instant)
        instant.is_a?(Time) ? instant : Time.iso8601(instant.to_s)
      end

      def local_midnight_utc(date)
        ZONE.local_to_utc(Time.utc(date.year, date.month, date.day))
      end
      private_class_method :local_midnight_utc
    end
  end
end
