require "lipgloss"

module Hive
  module Tui
    # Central Lipgloss::Style factory for the Charm backend's view layer.
    # Mirrors the curses palette's intent — cyan for agent_running, yellow
    # for error/recover, green for ready_*, default elsewhere — but uses
    # Lipgloss styles instead of curses color pairs.
    #
    # Symbol → ANSI string adapter is in `color`. `Lipgloss::Style#foreground`
    # rejects Symbol args at the C-extension boundary even though
    # `Lipgloss::ANSIColor.resolve` accepts them; we wrap once here so call
    # sites can stay symbol-friendly. See U2 verification at
    # docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md.
    #
    # Visual styles (color, bold, reverse) render correctly when stdout is
    # a tty. In non-tty test environments Lipgloss strips ANSI, so view
    # golden tests assert layout/text only — this module's tests assert
    # against Style getters/predicates (`get_foreground`, `bold?`,
    # `reverse?`) which work regardless of tty state.
    module Styles
      # Action_key → ANSI color symbol. Read by `for_action_key`.
      ACTION_KEY_COLORS = {
        "agent_running"   => :cyan,
        "error"           => :yellow,
        "recover_execute" => :yellow,
        "recover_review"  => :yellow
      }.freeze

      module_function

      # Convert :cyan / :yellow / etc. to the ANSI-256 index string Lipgloss
      # accepts. Hex strings ("#00ffff") and pre-resolved indices ("212")
      # pass through unchanged.
      def color(value)
        Lipgloss::ANSIColor.resolve(value)
      end

      # Per-row foreground style keyed by action_key. Returns a new Style
      # each call so callers can chain additional modifiers (`bold(true)`,
      # `reverse(true)`) without mutating the shared palette.
      def for_action_key(action_key)
        named = ACTION_KEY_COLORS[action_key]
        return Lipgloss::Style.new.foreground(color(named)) if named
        return Lipgloss::Style.new.foreground(color(:green)) if action_key.to_s.start_with?("ready_")

        Lipgloss::Style.new
      end

      # Header line — bold default-fg. Works on monochrome terminals.
      HEADER = Lipgloss::Style.new.bold(true)

      # Cursor row indicator: reverse video. Chosen because it survives
      # monochrome / 16-color / TrueColor consistently — the brainstorm's
      # "Linux way" hardware floor doesn't assume color is available.
      CURSOR_HIGHLIGHT = Lipgloss::Style.new.reverse(true)

      # Flash status line — yellow + bold. Used by `dispatch_and_flash_on_error`
      # in the App's update path.
      FLASH = Lipgloss::Style.new.foreground(color(:yellow)).bold(true)

      # Stalled-poll banner — yellow + reverse so it stands out when the
      # render loop is showing a snapshot older than the staleness threshold.
      STALLED = Lipgloss::Style.new.foreground(color(:yellow)).reverse(true)

      # Hint footer ("[?] help [/] filter [q] quit") — faint default-fg so
      # it recedes against the active grid content.
      HINT = Lipgloss::Style.new.faint(true)
    end
  end
end
