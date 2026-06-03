module Hive
  module Babysitter
    module Interval
      REGEX = /\A(?<amount>\d+)(?<unit>[smh])\z/.freeze

      module_function

      def parse(value)
        return value if value.is_a?(Integer) && value.positive?

        case value
        when String
          match = value.match(REGEX)
          raise Hive::ConfigError, "babysitter.interval must look like 30s, 10m, or 1h; got #{value.inspect}" unless match

          amount = match[:amount].to_i
          raise Hive::ConfigError, "babysitter.interval must be positive; got #{value.inspect}" unless amount.positive?

          multiplier = { "s" => 1, "m" => 60, "h" => 3600 }.fetch(match[:unit])
          amount * multiplier
        else
          raise Hive::ConfigError, "babysitter.interval must be an integer seconds value or duration string; got #{value.inspect}"
        end
      end
    end
  end
end
