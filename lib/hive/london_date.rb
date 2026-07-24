require "date"
require "time"
require "tzinfo"

module Hive
  module LondonDate
    ZONE = TZInfo::Timezone.get("Europe/London")

    module_function

    def today(now: Time.now)
      ZONE.to_local(parse_time(now).utc).to_date
    end

    def parse(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    end
  end
end
