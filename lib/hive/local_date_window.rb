require "date"

module Hive
  module LocalDateWindow
    module_function

    def local_today(now: Time.now)
      now.getlocal.to_date
    end

    def previous_local_day(now: Time.now)
      local_today(now: now) - 1
    end

    def parse_date(date)
      date.is_a?(Date) ? date : Date.parse(date.to_s)
    end
  end
end
