require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module UsageFooter
        BUCKET_LABELS = {
          today: "today",
          "7d": "7d",
          all: "all"
        }.freeze

        module_function

        def render(aggregate:, width:)
          line = text(aggregate)
          line = Format.truncate(line, width) if width
          Styles::HINT.render(line)
        end

        def text(aggregate)
          buckets = aggregate.fetch(:total, {})
          parts = BUCKET_LABELS.map do |bucket, label|
            "#{label} #{format_usage(buckets.fetch(bucket, zero_usage))}"
          end
          parts.join(" • ") + " • tokens"
        end

        def format_usage(usage)
          input = format_number(usage.fetch(:input, 0))
          output = format_number(usage.fetch(:output, 0))
          cached = format_number(usage.fetch(:cached, 0))
          "#{input}/#{output}/#{cached}"
        end

        def format_number(value)
          number = value.to_i
          return format_unit(number, 1_000_000, "M") if number >= 1_000_000
          return format_unit(number, 1_000, "k") if number >= 1_000

          number.to_s
        end

        def format_unit(number, threshold, suffix)
          scaled = number.to_f / threshold
          value = scaled < 10 ? format("%.1f", scaled) : scaled.round.to_s
          "#{value.sub(/\.0\z/, '')}#{suffix}"
        end

        def zero_usage
          { input: 0, output: 0, cached: 0 }
        end
      end
    end
  end
end
