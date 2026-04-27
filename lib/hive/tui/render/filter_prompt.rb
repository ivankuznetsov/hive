require "curses"

module Hive
  module Tui
    module Render
      # Single-line text input drawn at the bottom of the screen for
      # filter entry. Hand-rolled getch loop rather than Curses::Form so
      # the Esc key is recognised reliably (Form doesn't expose a clean
      # "cancel" event), and so the input bar can be redrawn without a
      # form pad.
      #
      # The result hash separates "commit" (Enter on a non-empty value)
      # from "clear" (Esc, or Enter on an empty buffer) so the caller —
      # GridState#set_filter — can branch on action without inspecting
      # the value. "cancel" is reserved for future use (Ctrl-C) and
      # currently never returned.
      class FilterPrompt
        PROMPT = "/"

        # `initial:` pre-populates the buffer so the prompt acts like an
        # in-place edit when the user presses `/` while a filter is
        # already active.
        def read(initial: nil)
          buffer = String.new(initial || "")
          loop do
            draw(buffer)
            ch = Curses.getch
            next if ch.nil?

            result = handle_keypress(ch, buffer)
            return result if result
          end
        end

        private

        # Returns nil to keep looping, or a result hash to terminate.
        # Splitting this out keeps `read` cyclomatic-complexity-friendly.
        def handle_keypress(ch, buffer)
          return { action: :clear, value: nil } if escape?(ch)
          return commit_or_clear(buffer) if enter?(ch)

          if backspace?(ch)
            buffer.chomp!(buffer[-1].to_s) unless buffer.empty?
            return nil
          end

          append_printable(ch, buffer)
          nil
        end

        def commit_or_clear(buffer)
          return { action: :clear, value: nil } if buffer.empty?

          { action: :commit, value: buffer.dup }
        end

        def escape?(ch)
          ch == 27 || ch == "\e"
        end

        def enter?(ch)
          ch == 10 || ch == 13 || ch == "\n" || ch == "\r" || ch == Curses::KEY_ENTER
        end

        def backspace?(ch)
          ch == 127 || ch == 8 || ch == "\b" || ch == Curses::KEY_BACKSPACE
        end

        def append_printable(ch, buffer)
          char = ch.is_a?(Integer) ? printable_chr(ch) : ch.to_s
          buffer << char if char && !char.empty? && char.match?(/\A[[:print:]]\z/)
        end

        # Curses returns Integer codes for special keys (KEY_DOWN etc).
        # Restrict chr conversion to the printable ASCII band so arrow
        # keys / fn keys don't sneak in as garbage bytes.
        def printable_chr(ch)
          return nil unless ch.between?(32, 126)

          ch.chr
        end

        def draw(buffer)
          row = Curses.lines - 1
          Curses.setpos(row, 0)
          Curses.clrtoeol
          Curses.addstr("#{PROMPT}#{buffer}")
          Curses.refresh
        end
      end
    end
  end
end
