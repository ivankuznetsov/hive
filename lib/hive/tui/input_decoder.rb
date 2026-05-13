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
        "\x03".b => Bubbletea::KeyMessage::KEY_CTRL_C,
        "\x05".b => Bubbletea::KeyMessage::KEY_CTRL_E
      }.freeze

      # Hard caps so a missing PASTE_END marker, a wedged escape prefix,
      # or a hostile paste source can't grow our buffers without bound.
      # MAX_PASTE_BYTES ≫ MAX_PENDING_BYTES because a real paste of a
      # commit message / patch chunk legitimately exceeds the pending
      # cap, but no realistic terminal sequence does.
      MAX_PASTE_BYTES = 1 << 20 # 1 MiB
      MAX_PENDING_BYTES = 4096

      # If we entered paste mode but never saw `\e[201~` within this
      # window, give up on the bracket and force-flush whatever was
      # buffered as text. Protects against a partial paste swallowing
      # every keystroke that follows.
      PASTE_TIMEOUT_SECONDS = 5.0

      def initialize
        @pending = +"".b
        @paste_buffer = +"".b
        @in_paste = false
        @paste_started_at = nil
      end

      # Drop every byte of in-flight state. PasteAwareRunner calls this
      # on `:new_idea` / `:filter` cancel transitions so an orphan paste
      # left over from a cancelled prompt cannot dump into the next
      # prompt.
      def reset!
        @pending.clear
        @paste_buffer.clear
        @in_paste = false
        @paste_started_at = nil
      end

      def drain(bytes)
        @pending << bytes.to_s.b
        messages = []
        guard_pending_overflow(messages)

        loop do
          break if @pending.empty?

          if @in_paste
            break unless drain_paste(messages)
          elsif @pending.start_with?(PASTE_START)
            consume(PASTE_START.bytesize)
            @paste_buffer.clear
            @in_paste = true
            @paste_started_at = Time.now
          elsif @pending.start_with?(PASTE_END)
            # Stray close marker (paste-state recovery, terminal echo,
            # nested-tmux quirk). Silently drop it; without this the
            # 6-byte sequence would sit at head of `@pending` forever
            # and wedge every subsequent keystroke behind it.
            consume(PASTE_END.bytesize)
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
      # actual Escape key. A paste sequence in progress is force-flushed
      # if it has exceeded PASTE_TIMEOUT_SECONDS — otherwise a dropped
      # `\e[201~` would leave `@in_paste = true` forever, swallowing
      # every subsequent keystroke into the orphan paste buffer.
      def flush
        if @in_paste
          return [] unless paste_timed_out?

          messages = []
          finalize_paste_timeout(messages)
          return messages
        end

        return [] unless @pending == ESC

        @pending.clear
        [ key_message(Bubbletea::KeyMessage::KEY_ESC) ]
      end

      private

      def paste_timed_out?
        return false if @paste_started_at.nil?

        (Time.now - @paste_started_at) > PASTE_TIMEOUT_SECONDS
      end

      def finalize_paste_timeout(messages)
        text = normalize_paste(@paste_buffer)
        # Asymmetry with `drain_paste`: the normal paste-end path
        # always emits an empty-text RawTextInput so the composer can
        # probe an image-only clipboard (U4). A timed-out paste does
        # NOT — we already lost the `\e[201~` marker, so synthesising
        # a clipboard probe on the way out would hit a foreign-mode
        # message after the flash, with no operator-visible benefit.
        messages << Messages::RawTextInput.new(text: text, paste: true) unless text.empty?
        messages << Messages::Flash.new(text: "paste timed out")
        @paste_buffer.clear
        @in_paste = false
        @paste_started_at = nil
        @pending = +"".b
      end

      # Pre-loop overflow check. If the operator hammered keys against a
      # decoder stuck waiting on a partial escape (a hypothetical wedge
      # we haven't found yet) `@pending` would grow without bound. Drop
      # everything and notify so the user knows input was lost rather
      # than silently dispatched.
      def guard_pending_overflow(messages)
        return if @pending.bytesize <= MAX_PENDING_BYTES

        @pending = +"".b
        @in_paste = false
        @paste_buffer.clear
        @paste_started_at = nil
        messages << Messages::Flash.new(text: "input buffer reset (overflow)")
      end

      def drain_paste(messages)
        if (idx = @pending.index(PASTE_END))
          append_paste_chunk(@pending.byteslice(0, idx), messages)
          consume(idx + PASTE_END.bytesize)
          # If the cap fired during the append, paste state was already
          # reset and a Flash was emitted; nothing else to do.
          if @in_paste
            @in_paste = false
            @paste_started_at = nil
            text = normalize_paste(@paste_buffer)
            @paste_buffer.clear
            messages << Messages::RawTextInput.new(text: text, paste: true)
          end
          return true
        end

        keep = suffix_prefix_length(@pending, PASTE_END)
        append_len = @pending.bytesize - keep
        if append_len.positive?
          append_paste_chunk(@pending.byteslice(0, append_len), messages)
          # If overflow reset paste state mid-stream, drop the residual
          # tail so later bytes don't keep accreting into the empty
          # buffer.
          unless @in_paste
            @pending = +"".b
            return true
          end
        end
        @pending = keep.positive? ? @pending.byteslice(append_len, keep).dup : +"".b
        false
      end

      # Append paste content but enforce MAX_PASTE_BYTES. On overflow,
      # discard the entire in-flight paste (truncated content is more
      # dangerous than dropped content — half a shell command pasted is
      # worse than none) and emit a Flash so the operator notices.
      def append_paste_chunk(chunk, messages)
        return if chunk.empty?
        return unless @in_paste

        if @paste_buffer.bytesize + chunk.bytesize > MAX_PASTE_BYTES
          @paste_buffer.clear
          @in_paste = false
          @paste_started_at = nil
          messages << Messages::Flash.new(text: "paste truncated (>#{MAX_PASTE_BYTES / 1024} KiB)")
          return
        end

        @paste_buffer << chunk
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
        # Esc-then-Enter (rapid cancel gesture) sometimes lands as a
        # single read with the CR/LF tailing the lone ESC. Without this
        # absorption the trailing newline would pop out as a separate
        # KEY_ENTER and trigger whatever Enter does in :grid.
        consume(1) if @pending.start_with?("\r".b, "\n".b)
        true
      end

      def drain_text(messages)
        len = printable_prefix_length
        if len.zero?
          # Head byte is non-ESC, non-control-key, non-printable
          # (an unmapped C0 byte: \x02, \x04, …). Without this drop
          # branch the byte sat at head of `@pending` forever and
          # every subsequent input was appended after it without
          # making forward progress. Silently consume.
          consume(1)
          return true
        end

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

      # Canonical paste-content normalizer. Order matters:
      #   1. scrub invalid UTF-8 first (downstream regexes are byte-safe
      #      after that).
      #   2. CR/LF/TAB → single space (multi-line paste flattens into
      #      a single-line title — same shape `Update#normalize_new_idea_text`
      #      enforces for direct typed input).
      #   3. Strip remaining C0 controls + DEL (\x00–\x1f, \x7f) so a
      #      paste containing an embedded ESC, BEL, or NUL can't smuggle
      #      a control byte into the buffer that later reads will
      #      mis-interpret. Done AFTER the whitespace rewrite so legit
      #      \t and \n are already gone.
      #   4. Collapse runs of spaces.
      #
      # Trailing/leading whitespace is intentionally preserved at this
      # layer: `:filter` mode and the new-idea composer route raw paste
      # buffers through here, and a global `.strip` would silently
      # discard user-intended boundary spaces in non-image pastes. The
      # image-path probe path already strips via
      # `Clipboard.normalized_path` before path resolution, so dropping
      # the strip here doesn't change image-path detection.
      def normalize_paste(bytes)
        bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub
             .gsub(/[\r\n\t]+/, " ")
             .gsub(/[\x00-\x1f\x7f]/, "")
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
