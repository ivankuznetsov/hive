require "curses"

module Hive
  module Tui
    module Render
      # Tiny `init_pair` registry for the grid renderer. Action keys get
      # mapped to color pairs by category (running / error-class / ready)
      # rather than per-action so the palette stays at four foreground
      # colors plus default. Headers and the flash bar share `bold`
      # attribute application at the call site, not as separate pairs.
      #
      # Pair 0 is "default fg/bg" by convention — Curses reserves it and
      # `init_pair(0, ...)` is undefined. Every helper that does the
      # lookup falls back to PAIR_DEFAULT for unrecognised action keys.
      module Palette
        module_function

        PAIR_DEFAULT = 0
        PAIR_AGENT_RUNNING = 1
        PAIR_ERROR = 2
        PAIR_READY = 3
        PAIR_HEADER = 4
        PAIR_FLASH = 5

        # `use_default_colors` lets us leave the bg as terminal-default
        # (-1) so the TUI doesn't paint over the user's transparent
        # background. Falls back to COLOR_BLACK on Curses builds without
        # that extension.
        def init!
          return unless Curses.has_colors?

          Curses.start_color
          attempt_default_colors
          init_pair_with_fallback(PAIR_AGENT_RUNNING, Curses::COLOR_CYAN)
          init_pair_with_fallback(PAIR_ERROR, Curses::COLOR_YELLOW)
          init_pair_with_fallback(PAIR_READY, Curses::COLOR_GREEN)
          init_pair_with_fallback(PAIR_HEADER, Curses::COLOR_WHITE)
          init_pair_with_fallback(PAIR_FLASH, Curses::COLOR_YELLOW)
        end

        # Resolve an action_key (from Snapshot::Row#action_key) to the
        # appropriate pair index. The renderer ORs in Curses::A_BOLD on
        # top of these for emphasis where applicable.
        def for_action_key(action_key)
          case action_key
          when "agent_running" then PAIR_AGENT_RUNNING
          when "error", "recover_execute", "recover_review" then PAIR_ERROR
          when /\Aready_/ then PAIR_READY
          else PAIR_DEFAULT
          end
        end

        # Older Curses builds don't expose use_default_colors; rescue any
        # error so init! still returns truthy and the renderer falls
        # back to COLOR_BLACK in init_pair_with_fallback.
        def attempt_default_colors
          return unless Curses.respond_to?(:use_default_colors)

          Curses.use_default_colors
        rescue StandardError
          nil
        end

        def init_pair_with_fallback(pair, fg)
          Curses.init_pair(pair, fg, -1)
        rescue StandardError
          Curses.init_pair(pair, fg, Curses::COLOR_BLACK)
        end
      end
    end
  end
end
