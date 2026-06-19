module Hive
  module Tui
    # Shared text-sanitization helpers for any surface that renders
    # operator-supplied or subprocess-derived strings (marker attrs,
    # captured stderr, exception messages) into the TUI's status line
    # or row columns. Without sanitisation, an embedded ANSI CSI
    # sequence or stray control byte can corrupt lipgloss column
    # alignment or hijack the cursor; the renderer treats `\e[2J`
    # (clear screen) the same way every other terminal does.
    module Text
      # ANSI Control Sequence Introducer: `ESC [ <params> <intermediates>
      # <final>` per ECMA-48. Covers SGR (colour), CUP (cursor-position),
      # ED (erase-display), and the rest of the 0x40–0x7E final-byte
      # CSI repertoire — including the obscure cursor and screen-clear
      # commands that operator-supplied strings should not be able to
      # reach. Does NOT cover the rare two-byte escapes (`ESC c` reset,
      # `ESC ( B` charset-switch); those land in the control-char pass
      # below via the literal `\e` byte.
      ANSI_CSI_PATTERN = /\e\[[\d;?]*[ -\/]*[@-~]/.freeze

      # 0x00–0x1F C0 + 0x7F DEL. Covers the plain control bytes that
      # would corrupt a single-line status flash (most importantly
      # CR/LF/0x08 which lipgloss does not strip on its own).
      CONTROL_CHARS_PATTERN = /[\x00-\x1f\x7f]/.freeze

      module_function

      # Idempotent: strip ANSI CSI sequences first (so the trailing
      # bytes do not survive into the second pass), then replace each
      # remaining control byte with `?` so column-width math stays
      # one-cell-per-character. nil/non-string input returns the empty
      # string — every caller is concerned with display safety, not
      # with surfacing a TypeError on a missing field.
      #
      # Cross-reference: `Hive::Bot::Format.strip_control_chars` does the
      # reverse for HTML output — it DELETES control bytes (no column
      # constraint there). The replace-vs-delete split is deliberate; do
      # not unify the two.
      def sanitize(text)
        text.to_s.gsub(ANSI_CSI_PATTERN, "").gsub(CONTROL_CHARS_PATTERN, "?")
      end
    end
  end
end
