require "date"
require "time"

module Hive
  module Digest
    module Window
      module_function

      def local_today(now: Time.now)
        now.getlocal.to_date
      end

      def on_local_date?(instant, date)
        parse_time(instant).getlocal.to_date == parse_date(date)
      end

      def parse_date(date)
        date.is_a?(Date) ? date : Date.parse(date.to_s)
      end

      def parse_time(instant)
        instant.is_a?(Time) ? instant : Time.parse(instant.to_s)
      end
    end
  end
end
