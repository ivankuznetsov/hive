require "bubbletea"
require "hive/tui/input_decoder"

module Hive
  module Tui
    # Bubbletea::Runner variant that drains every raw input chunk
    # through Hive::Tui::InputDecoder. The stock runner's poll_event
    # bridge drops unconsumed bytes after the first parsed event.
    class PasteAwareRunner < Bubbletea::Runner
      def initialize(model, **options)
        super
        @input_decoder = InputDecoder.new
      end

      private

      def run_loop
        frame_duration = 1.0 / @options[:fps]
        last_frame = Time.now

        while @running
          check_resize
          process_pending_messages
          process_input
          process_ticks

          now = Time.now
          if now - last_frame >= frame_duration
            render
            last_frame = now
          end
        end
      end

      def process_input
        raw = @program.read_raw_input(@options[:input_timeout])
        messages = raw ? @input_decoder.drain(raw) : @input_decoder.flush
        messages.each { |message| handle_message(message) }
      end
    end
  end
end
