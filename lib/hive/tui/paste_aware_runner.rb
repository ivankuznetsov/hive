require "bubbletea"
require "hive/tui/input_decoder"

module Hive
  module Tui
    # Bubbletea::Runner variant that drains every raw input chunk
    # through Hive::Tui::InputDecoder. The stock runner's poll_event
    # bridge drops unconsumed bytes after the first parsed event.
    #
    # Pinned to bubbletea 0.1.4 — the run_loop / process_input override
    # touches private superclass internals (`@program`, `@running`,
    # `@options`) that have no semver guarantee. The boot-time assertion
    # below trips loudly on any silent gem bump so the override doesn't
    # silently degrade.
    class PasteAwareRunner < Bubbletea::Runner
      SUPPORTED_BUBBLETEA_VERSION = "0.1.4".freeze

      if defined?(Bubbletea::VERSION) && Bubbletea::VERSION != SUPPORTED_BUBBLETEA_VERSION
        raise "PasteAwareRunner is bound to bubbletea #{SUPPORTED_BUBBLETEA_VERSION}, " \
              "got #{Bubbletea::VERSION}. Re-audit run_loop/process_input overrides " \
              "before relaxing this guard."
      end

      attr_reader :input_decoder

      # Modes whose Esc-cancel path resets in-prompt buffers. Tracked so
      # the decoder can be reset on transition out of one of them — an
      # orphan paste held in `@input_decoder` would otherwise dump into
      # the next prompt the operator opens.
      EDITABLE_MODES = %i[new_idea filter].freeze

      def initialize(model, **options)
        super
        @input_decoder = InputDecoder.new
        @last_editable_mode = nil
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
        reset_decoder_on_cancel
      end

      # Inspect the model's current mode after a batch of messages has
      # been handled. If we just transitioned out of an editable mode
      # (`:new_idea` or `:filter`) the decoder is purged so any half-
      # parsed paste / pending escape doesn't leak into the next mode's
      # input stream. The two-step latch (`@last_editable_mode`) is
      # needed because we only have access to the new mode here — we
      # remember the previous one across loop iterations.
      def reset_decoder_on_cancel
        mode = current_mode
        if mode != @last_editable_mode && @last_editable_mode
          @input_decoder.reset!
        end
        @last_editable_mode = EDITABLE_MODES.include?(mode) ? mode : nil
      end

      def current_mode
        bubble = @model
        return nil unless bubble.respond_to?(:hive_model)

        hive = bubble.hive_model
        hive.respond_to?(:mode) ? hive.mode : nil
      end
    end
  end
end
