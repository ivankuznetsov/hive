require "bubbletea"
require "hive/tui/messages"

module Hive
  module Tui
    # Stateful raw terminal-byte decoder for Bubble Tea input. The
    # bubbletea-ruby 0.1.4 Program#poll_event bridge parses one event
    # from each raw read and drops the rest of the bytes; this decoder
    # drains the whole chunk and keeps partial escape / paste sequences
    # across reads.
    class InputDecoder
      ESC = "\e".b.freeze
      PASTE_START = "\e[200~".b.freeze
      PASTE_END = "\e[201~".b.freeze

      SEQUENCES = {
        "\e[A".b => Bubbletea::KeyMessage::KEY_UP,
        "\e[B".b => Bubbletea::KeyMessage::KEY_DOWN,
        "\e[C".b => Bubbletea::KeyMessage::KEY_RIGHT,
        "\e[D".b => Bubbletea::KeyMessage::KEY_LEFT,
        "\eOA".b => Bubbletea::KeyMessage::KEY_UP,
        "\eOB".b => Bubbletea::KeyMessage::KEY_DOWN,
        "\eOC".b => Bubbletea::KeyMessage::KEY_RIGHT,
        "\eOD".b => Bubbletea::KeyMessage::KEY_LEFT,
        "\e[H".b => Bubbletea::KeyMessage::KEY_HOME,
        "\e[F".b => Bubbletea::KeyMessage::KEY_END,
        "\eOH".b => Bubbletea::KeyMessage::KEY_HOME,
        "\eOF".b => Bubbletea::KeyMessage::KEY_END,
        "\e[1~".b => Bubbletea::KeyMessage::KEY_HOME,
        "\e[4~".b => Bubbletea::KeyMessage::KEY_END,
        "\e[3~".b => Bubbletea::KeyMessage::KEY_DELETE,
        "\e[Z".b => Bubbletea::KeyMessage::KEY_SHIFT_TAB
      }.freeze

      CONTROL_KEYS = {
        "\r".b => Bubbletea::KeyMessage::KEY_ENTER,
        "\n".b => Bubbletea::KeyMessage::KEY_ENTER,
        "\t".b => Bubbletea::KeyMessage::KEY_TAB,
        "\x7f".b => Bubbletea::KeyMessage::KEY_BACKSPACE,
        "\x01".b => Bubbletea::KeyMessage::KEY_CTRL_A,
        "\x05".b => Bubbletea::KeyMessage::KEY_CTRL_E
      }.freeze

      def initialize
        @pending = +"".b
        @paste_buffer = +"".b
        @in_paste = false
      end

      def drain(bytes)
        @pending << bytes.to_s.b
        messages = []

        loop do
          break if @pending.empty?

          if @in_paste
            break unless drain_paste(messages)
          elsif @pending.start_with?(PASTE_START)
            consume(PASTE_START.bytesize)
            @paste_buffer.clear
            @in_paste = true
          elsif escape_leader?
            break unless drain_escape(messages)
          elsif control_key?
            messages << key_message(CONTROL_KEYS.fetch(@pending.byteslice(0, 1)))
            consume(1)
          else
            break unless drain_text(messages)
          end
        end

        messages
      end

      # Called by PasteAwareRunner on input timeout. A lone ESC is an
      # actual Escape key; a paste sequence in progress is not flushed.
      def flush
        return [] if @in_paste
        return [] unless @pending == ESC

        @pending.clear
        [ key_message(Bubbletea::KeyMessage::KEY_ESC) ]
      end

      private

      def drain_paste(messages)
        if (idx = @pending.index(PASTE_END))
          @paste_buffer << @pending.byteslice(0, idx)
          consume(idx + PASTE_END.bytesize)
          @in_paste = false
          text = normalize_paste(@paste_buffer)
          @paste_buffer.clear
          messages << Messages::RawTextInput.new(text: text, paste: true) unless text.empty?
          return true
        end

        keep = suffix_prefix_length(@pending, PASTE_END)
        append_len = @pending.bytesize - keep
        @paste_buffer << @pending.byteslice(0, append_len) if append_len.positive?
        @pending = keep.positive? ? @pending.byteslice(append_len, keep).dup : +"".b
        false
      end

      def drain_escape(messages)
        if (sequence = sequence_match)
          consume(sequence.bytesize)
          messages << key_message(SEQUENCES.fetch(sequence))
          return true
        end

        return false if escape_prefix?(@pending)

        consume(1)
        messages << key_message(Bubbletea::KeyMessage::KEY_ESC)
        true
      end

      def drain_text(messages)
        len = printable_prefix_length
        return false if len.zero?

        bytes = @pending.byteslice(0, len)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          return false if len == @pending.bytesize

          consume(1)
          return true
        end

        consume(len)
        if text.length == 1
          messages << printable_key_message(text)
        else
          messages << Messages::RawTextInput.new(text: text, paste: false)
        end
        true
      end

      def printable_prefix_length
        idx = 0
        while idx < @pending.bytesize
          byte = @pending.getbyte(idx)
          break if byte == 27 || byte < 32 || byte == 127

          idx += 1
        end
        idx
      end

      def escape_leader?
        @pending.start_with?(ESC)
      end

      def control_key?
        CONTROL_KEYS.key?(@pending.byteslice(0, 1))
      end

      def sequence_match
        SEQUENCES.keys.find { |seq| @pending.start_with?(seq) }
      end

      def escape_prefix?(bytes)
        ([ PASTE_START, PASTE_END ] + SEQUENCES.keys).any? do |seq|
          seq.start_with?(bytes)
        end
      end

      def suffix_prefix_length(bytes, marker)
        max = [ bytes.bytesize, marker.bytesize - 1 ].min
        max.downto(1).find { |len| bytes.end_with?(marker.byteslice(0, len)) } || 0
      end

      def normalize_paste(bytes)
        bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub
             .gsub(/[\r\n\t]+/, " ")
             .gsub(/ {2,}/, " ")
      end

      def key_message(key_type, runes: [])
        Bubbletea::KeyMessage.new(key_type: key_type, runes: runes)
      end

      def printable_key_message(text)
        if text == " "
          key_message(Bubbletea::KeyMessage::KEY_SPACE, runes: [ 32 ])
        else
          key_message(Bubbletea::KeyMessage::KEY_RUNES, runes: text.codepoints)
        end
      end

      def consume(length)
        @pending = @pending.byteslice(length, @pending.bytesize - length)&.dup || +"".b
      end
    end
  end
end
