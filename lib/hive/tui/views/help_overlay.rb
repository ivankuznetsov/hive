require "lipgloss"
require "hive/tui/help"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::HelpOverlay.render(model) → String`.
      # Renders the keybinding cheatsheet from `Hive::Tui::Help::BINDINGS`
      # grouped by mode header, wrapped in a Lipgloss bordered box.
      #
      # When `model.mode == :help`, U10's view dispatcher returns this
      # output as the full frame. Composing it as an overlay over the
      # underlying grid is a future polish — for v1 a full-screen modal
      # matches the curses behavior (curses cleared the screen before
      # painting the overlay, so users never saw underlying content).
      module HelpOverlay
        MODE_HEADERS = {
          grid: "Grid mode",
          triage: "Triage mode (Enter on a 'review_findings' row)",
          log_tail: "Log tail mode (Enter on an 'agent_running' row)",
          filter: "Filter prompt",
          new_idea: "New-idea prompt (n)"
        }.freeze

        TITLE = "hive tui — keybindings".freeze
        DISMISS_HINT = "press any key to dismiss".freeze

        module_function

        def render(model)
          lines = build_lines
          inner = Lipgloss.join_vertical(Lipgloss::TOP, *lines)
          # Bordered, padded block. Width clamps so the overlay stays
          # within the terminal even when the cheatsheet's longest line
          # is wider — Lipgloss handles the wrap/truncate.
          width = [ model.cols.to_i - 4, 20 ].max
          Lipgloss::Style.new
                         .border(Lipgloss::Border::NORMAL)
                         .padding(1, 2)
                         .width(width)
                         .render(inner)
        end

        # @api private — exposed for tests.
        def build_lines
          rows = [ Styles::HEADER.render(TITLE), "" ]
          MODE_HEADERS.each do |mode, header|
            entries = Help::BINDINGS.select { |b| b[:mode] == mode }
            next if entries.empty?

            rows << Styles::HEADER.render(header)
            entries.each { |b| rows << format("  %-7s  %s", b[:key], b[:description]) }
            rows << ""
          end
          rows << Styles::HINT.render(DISMISS_HINT)
          rows
        end
      end
    end
  end
end
