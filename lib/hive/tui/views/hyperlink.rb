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
      end
    end
  end
end
