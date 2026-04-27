require "curses"

module Hive
  module Tui
    module KeyMap
      # Curses-aware translation layer for raw `Curses.getch` return
      # values into the surface `KeyMap.dispatch` consumes (single-char
      # Strings for printable input, `:key_*` Symbols for special keys).
      # Lives in its own file so the parent `key_map.rb` stays
      # curses-free and unit-testable without a tty; only the render
      # layer (which already requires curses) loads this module.
      module CursesKeys
        module_function

        # Curses returns Integer codes for special keys and a single-char
        # String for printable input. Map to the surface KeyMap expects:
        # `:key_*` Symbols for navigation, single-char Strings for the rest.
        def translate(ch)
          return ch if ch.is_a?(String)
          return :unknown unless ch.is_a?(Integer)

          case ch
          when Curses::KEY_DOWN then :key_down
          when Curses::KEY_UP then :key_up
          when Curses::KEY_ENTER, 10, 13 then :key_enter
          when 27 then :key_escape
          else printable_or_unknown(ch)
          end
        end

        # Restrict raw integer-to-chr conversion to the printable ASCII band
        # so unmapped function keys / escape sequences don't surface as
        # garbage bytes that KeyMap then routes as no-ops.
        def printable_or_unknown(ch)
          return ch.chr if ch.between?(32, 126)

          :unknown
        end
      end
    end
  end
end
