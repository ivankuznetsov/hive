require "hive/bot/logger"

module Hive
  module Eval
    class CapturingLogger
      Event = Struct.new(:name, :attrs, :t, keyword_init: true)

      attr_reader :events

      def initialize(now: -> { Time.now })
        @now = now
        @events = []
      end

      def event(name, **attrs)
        @events << Event.new(name: name.to_sym, attrs: attrs.transform_keys(&:to_sym), t: @now.call)
      end

      def events_named(name)
        @events.select { |event| event.name == name.to_sym }
      end

      def events_with(name, **attr_subset)
        expected = attr_subset.transform_keys(&:to_sym)
        events_named(name).select do |event|
          expected.all? { |key, value| event.attrs[key] == value }
        end
      end

      def count_named(name)
        events_named(name).length
      end

      def close; end
    end
  end
end
