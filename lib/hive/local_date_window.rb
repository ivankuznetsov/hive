require "date"

module Hive
  module LocalDateWindow
    module_function

    def local_today(now: Time.now)
      now.getlocal.to_date
    end

    def parse_date(date)
      date.is_a?(Date) ? date : Date.parse(date.to_s)
    end
  end
end
