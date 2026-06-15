require "hive/pr"

module Hive
  module Bot
    # HTML/text formatting helpers for Telegram bot messages: HTML escaping
    # for `parse_mode: :html` payloads and the safe PR-link builder.
    module Format
      module_function

      def html_escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def html_attr_escape(text)
        html_escape(text).gsub('"', "&quot;")
      end

      # Build a safe `<a href="…">#NNN</a>` for a PR URL, or nil unless the
      # input is BOTH a parseable PR number AND a valid http(s) URL. That
      # paired gate is the security contract: it blocks `javascript:` (and
      # any other non-http scheme) from reaching a rendered Telegram
      # message, so a malformed or hostile href degrades to nil — the caller
      # then sends plain text — rather than emitting an anchor. Shares the
      # Hive::Pr.valid_http_url? predicate with the TUI hyperlink builder so
      # the two link surfaces can't drift on what counts as a safe href.
      def html_pr_link(url)
        clean_url = strip_control_chars(url).strip
        number = Hive::Pr.number(clean_url)
        return nil unless number && Hive::Pr.valid_http_url?(clean_url)

        %(<a href="#{html_attr_escape(clean_url)}">#{html_escape(number)}</a>)
      end

      # Control-char stripper for HTML output: DELETES C0/DEL bytes
      # outright. Deliberately diverges from Hive::Tui::Text.sanitize, which
      # REPLACES the same bytes with `?` to keep TUI column-width math
      # one-cell-per-character. HTML has no column-alignment constraint, so
      # removal is correct here. Keep the two strippers separate — do not
      # "unify" them.
      def strip_control_chars(text)
        text.to_s.gsub(/[\x00-\x1f\x7f]/, "")
      end
    end
  end
end
