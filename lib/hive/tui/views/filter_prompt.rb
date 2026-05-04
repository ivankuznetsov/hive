require "lipgloss"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::FilterPrompt.render(model) → String`.
      # Returns a single line: `/<filter_buffer>` — used as the bottom
      # row when `model.mode == :filter`. U10's view dispatcher composes
      # the underlying grid frame with this strip pinned to the last
      # row (replacing the help hint).
      #
      # Keystroke handling lives entirely in `Update`: each printable
      # char becomes `Messages::FilterCharAppended`, Backspace becomes
      # `FilterCharDeleted`, Enter becomes `FilterCommitted`, Esc
      # becomes `FilterCancelled`. The view is read-only.
      module FilterPrompt
        PROMPT = "/".freeze

        module_function

        def render(model, width: model.cols.to_i)
          # Cursor block at end of buffer — visual feedback that the
          # input is live. Render via Lipgloss reverse so it pops on
          # both light and dark themes. Long buffers slide the visible
          # window so the cursor stays at the right edge (real-shell
          # behavior); without this the rendered line overflows the
          # terminal and disappears off the right side.
          buffer = model.filter_buffer.to_s
          available = [ width - PROMPT.length - 2, 1 ].max
          visible_buffer = buffer.length <= available ? buffer : buffer[-available, available].to_s
          cursor = Styles::CURSOR_HIGHLIGHT.render(" ")
          "#{PROMPT}#{visible_buffer}#{cursor}"
        end
      end
    end
  end
end
