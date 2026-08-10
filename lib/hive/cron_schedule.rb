module Hive
  # Shared five-field UTC cron grammar for reviewed module manifests and the
  # runtime scheduler. Parsing every comma branch up front prevents a matching
  # early branch from hiding malformed trailing syntax.
  module CronSchedule
    RANGES = [ 0..59, 0..23, 1..31, 1..12, 0..6 ].freeze
    Selector = Data.define(:range, :step)

    module_function

    def valid?(schedule)
      parse(schedule)
      true
    rescue Hive::ConfigError
      false
    end

    def match?(schedule, time)
      values = [ time.min, time.hour, time.day, time.month, time.wday ]
      parse(schedule).each_with_index.all? do |selectors, index|
        value = values.fetch(index)
        selectors.any? do |selector|
          selector.range.cover?(value) &&
            ((value - selector.range.begin) % selector.step).zero?
        end
      end
    end

    def parse(schedule)
      fields = schedule.to_s.split
      unless fields.length == RANGES.length
        raise Hive::ConfigError, "module schedule must contain five cron fields"
      end

      fields.each_with_index.map do |field, index|
        parse_field(field, RANGES.fetch(index))
      end.freeze
    end

    def parse_field(field, allowed)
      parts = field.split(",", -1)
      raise Hive::ConfigError, "module schedule field is malformed" if parts.any?(&:empty?)

      parts.map do |part|
        pieces = part.split("/", -1)
        unless pieces.length.between?(1, 2) && pieces.none?(&:empty?)
          raise Hive::ConfigError, "module schedule field is malformed"
        end
        base = pieces.fetch(0)
        step = pieces.length == 2 ? Integer(pieces.fetch(1), 10) : 1
        raise Hive::ConfigError, "module schedule step must be positive" unless step.positive?

        selected = if base == "*"
          allowed
        elsif base.include?("-")
          bounds = base.split("-", -1)
          raise Hive::ConfigError, "module schedule field is malformed" unless bounds.length == 2
          Range.new(Integer(bounds.fetch(0), 10), Integer(bounds.fetch(1), 10))
        else
          number = Integer(base, 10)
          Range.new(number, number)
        end
        unless allowed.cover?(selected.begin) && allowed.cover?(selected.end) &&
               selected.begin <= selected.end
          raise Hive::ConfigError, "module schedule field is outside its allowed range"
        end
        Selector.new(range: selected, step: step).freeze
      end.freeze
    rescue ArgumentError, TypeError
      raise Hive::ConfigError, "module schedule field is malformed"
    end
    private_class_method :parse_field
  end
end
