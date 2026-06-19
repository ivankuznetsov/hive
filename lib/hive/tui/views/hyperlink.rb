require "hive/pr"
require "hive/tui/text"

module Hive
  module Tui
    module Views
      # Builds OSC 8 terminal hyperlinks (`ESC]8;;URL ESC\ label
      # ESC]8;;ESC\`) so PR numbers render as clickable links in the TUI and
      # `hive status` text output. Falls back to the plain label whenever
      # hyperlinks are disabled (non-tty) or the URL fails the shared
      # Hive::Pr.valid_http_url? gate (e.g. a `javascript:` scheme), so an
      # untrusted href can never reach the terminal.
      module Hyperlink
        module_function

        def osc8(visible, url, enabled:)
          label = visible.to_s
          return label unless enabled

          href = Hive::Tui::Text.sanitize(url).strip
          return label unless Hive::Pr.valid_http_url?(href)

          "\e]8;;#{href}\e\\#{label}\e]8;;\e\\"
        end

        # Wrap the visible characters at `[offset, offset + length)` of an
        # already-padded string with an OSC 8 link, leaving the surrounding
        # rjust/ljust padding (and any trailing text) OUTSIDE the link so the
        # cell keeps its visible width. Both PR-cell surfaces — `hive status`
        # text mode (Hive::Commands::Status#display_identity_with_pr) and
        # Views::TasksPane#pr_cell — build the plain padded string first, then
        # splice here, because String#ljust counts the link's invisible escape
        # bytes and would otherwise eat the padding. The wrapped run is read
        # back out of `padded` so it always matches the bytes already on the
        # row. URL-safety/tty gating is delegated to osc8: a disabled tty or an
        # href that fails Hive::Pr.valid_http_url? returns the string unchanged.
        def splice(padded, offset, length, url, enabled:)
          token = padded[offset, length].to_s
          linked = osc8(token, url, enabled: enabled)
          return padded if linked == token

          "#{padded[0...offset]}#{linked}#{padded[(offset + length)..]}"
        end
      end
    end
  end
end
