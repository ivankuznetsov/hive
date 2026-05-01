require "lipgloss"

module Hive
  module Tui
    # Central Lipgloss::Style factory for the Charm backend's view layer.
    #
    # v2 palette ("Charm-modern", origin: docs/brainstorms/2026-05-01-…):
    #   blue    → ready_*       (next action available; calm forward motion)
    #   magenta → agent_running (active work in flight; visually distinct)
    #   red     → error / recover_* (attention required; failure-class)
    #   yellow  → needs_input / review_findings (user-blocking)
    #   green   → archived       (terminal "done" state)
    #   default → everything else
    #
    # v1 used cyan for agent_running and yellow for error/recover; v2
    # reshapes the palette so urgency (red) and progress (blue → magenta
    # → green) read by hue alone. Cursor highlight is still reverse-video
    # (works on monochrome) so the selected row is visible regardless of
    # color support.
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
      # v2 palette — see module docstring above for the full mapping.
      ACTION_KEY_COLORS = {
        "agent_running"   => :magenta,
        "error"           => :red,
        "recover_execute" => :red,
        "recover_review"  => :red,
        "needs_input"     => :yellow,
        "review_findings" => :yellow,
        "archived"        => :green
      }.freeze

      module_function

      # Convert :cyan / :yellow / etc. to the ANSI-256 index string Lipgloss
      # accepts. Hex strings ("#00ffff") and pre-resolved indices ("212")
      # pass through unchanged.
      def color(value)
        Lipgloss::ANSIColor.resolve(value)
      end

      # Per-row foreground style keyed by action_key. Returns a memoized
      # Style instance — render(line) is a pure read on the Style, so
      # callers can't observe shared mutation. Pre-F23 every render row
      # allocated a fresh Style + crossed the FFI boundary to set
      # foreground; ~6000 allocations/sec at 60fps × 50 rows. The
      # memoized table caches one Style per distinct color key.
      ACTION_KEY_STYLES = {
        "agent_running"   => Lipgloss::Style.new.foreground(color(:magenta)).freeze,
        "error"           => Lipgloss::Style.new.foreground(color(:red)).freeze,
        "recover_execute" => Lipgloss::Style.new.foreground(color(:red)).freeze,
        "recover_review"  => Lipgloss::Style.new.foreground(color(:red)).freeze,
        "needs_input"     => Lipgloss::Style.new.foreground(color(:yellow)).freeze,
        "review_findings" => Lipgloss::Style.new.foreground(color(:yellow)).freeze,
        "archived"        => Lipgloss::Style.new.foreground(color(:green)).freeze
      }.freeze

      # All `ready_*` action keys share one Style instance. v1 used green;
      # v2 uses blue so green is reserved for the terminal "done" state
      # (archived). One Style, one FFI cost, one allocation per render.
      READY_STYLE = Lipgloss::Style.new.foreground(color(:blue)).freeze
      DEFAULT_STYLE = Lipgloss::Style.new.freeze

      def for_action_key(action_key)
        return ACTION_KEY_STYLES.fetch(action_key) if ACTION_KEY_STYLES.key?(action_key)
        return READY_STYLE if action_key.to_s.start_with?("ready_")

        DEFAULT_STYLE
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

      # ---- v2 two-pane border styles ----
      # Both panes carry a rounded border. The focused pane uses a bright
      # cyan accent; the inactive pane uses faint default-fg so the
      # operator's eye is drawn to the active pane without losing the
      # inactive pane's outline. Lipgloss falls back to ASCII corners on
      # terminals without Unicode box-drawing — no boot guard needed.
      PANE_FOCUSED_BORDER = Lipgloss::Style.new
        .border(Lipgloss::ROUNDED_BORDER)
        .border_foreground(color(:cyan))
        .freeze

      PANE_DIM_BORDER = Lipgloss::Style.new
        .border(Lipgloss::ROUNDED_BORDER)
        .border_foreground(color(:bright_black))
        .freeze
    end
  end
end
