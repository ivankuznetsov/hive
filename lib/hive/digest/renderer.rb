require "date"
require "hive/digest/categories"
require "hive/digest/window"

module Hive
  module Digest
    module Renderer
      # Shares the single ordered category set with the categorizer
      # (see Hive::Digest::Categories) so an accepted category can never
      # be silently dropped here for want of a render section.
      CATEGORY_ORDER = Categories::ORDERED

      # Telegram hard-caps a message at 4096 chars; the chunker
      # (Telegram#split_message) prefers to cut on the last newline inside that
      # window and only hard-cuts mid-text as a fallback. A hard cut landing
      # between a MarkdownV2 `\` and the char it escapes produces an invalid
      # escape → a 400 that fails the whole send. Model summaries and the
      # (attacker-influenceable) display label are not length-bounded, so cap
      # each well under the limit (MarkdownV2 escaping at most doubles the
      # length) BEFORE escaping, so a single rendered line can never approach
      # the chunk boundary in the first place.
      MAX_SUMMARY_LENGTH = 600
      # The label is a short title, so a much tighter cap is plenty; together
      # with the summary cap it keeps the whole "• summary — [label](url)" line
      # well under 4096 even after MarkdownV2 escaping.
      MAX_LABEL_LENGTH = 200

      # The digest's brand title and its Telegram hashtag, rendered as
      # "*Hive* #Digest" above the date. The hashtag is left outside the bold
      # span so Telegram still parses it as a tappable tag.
      BRAND = "Hive".freeze
      HASHTAG = "#Digest".freeze
      # Thin divider above the global stats footer.
      FOOTER_DIVIDER = "──────────".freeze
      # Cap the model's one-line overall summary the same way as per-item
      # summaries so the rendered Summary block can't approach the chunk limit.
      MAX_OVERALL_SUMMARY_LENGTH = 600

      RESERVED_MDV2 = /([\\_*\[\]()~`>#+\-=|{}.!])/

      # Inside a MarkdownV2 inline link destination only ')' and '\'
      # are special and must be escaped; every other URL character is
      # passed through untouched (Telegram MarkdownV2 spec). One
      # malformed URL would otherwise fail the whole day's send_message.
      RESERVED_LINK_TARGET = /([\\)])/

      # Inside a MarkdownV2 code entity (`` `…` ``) Telegram treats only '`'
      # and '\' as special; every other char (including the general reserved
      # set `-`/`.`/`_` etc.) is literal. Escaping with the full escape_mdv2
      # set would render stray backslashes and can even 400 the send, so a
      # code span must use this reduced set — mirrors RESERVED_LINK_TARGET.
      RESERVED_CODE_SPAN = /([\\`])/

      module_function

      def render(grouped, date:, summary: nil, totals: nil)
        projects = Array(grouped).filter_map do |project_name, items|
          render_project(project_name, Array(items))
        end

        return empty if projects.empty?

        blocks = [ header(date) ]
        blocks << render_summary(summary) unless blank?(summary)
        blocks.concat(projects)
        footer = render_footer(totals)
        blocks << footer if footer
        blocks.join("\n\n")
      end

      def empty
        "Nothing shipped today 🌙"
      end

      def failed(date)
        "⚠️ Shipped digest for #{escape_mdv2(Window.parse_date(date).iso8601)} failed to generate\\."
      end

      def escape_mdv2(text)
        text.to_s.gsub(RESERVED_MDV2) { "\\#{$1}" }
      end

      # "*Hive* #Digest" then a human date line, e.g. "Fri, 19 June 2026".
      def header(date)
        "*#{escape_mdv2(BRAND)}* #{escape_mdv2(HASHTAG)}\n#{escape_mdv2(format_date(date))}"
      end

      def format_date(date)
        Window.parse_date(date).strftime("%a, %-d %B %Y")
      end

      # The model's one friendly sentence overview, under an italic heading.
      # Bounded + escaped because it is untrusted, length-unbounded model text.
      def render_summary(summary)
        "_Summary_\n#{escape_mdv2(truncate_overall_summary(summary))}"
      end

      # Global totals across every shipped project, on one line under a thin
      # divider. PRs is always known from the collected items; Lines/Commits
      # come from a per-PR `gh` lookup, so they appear only when at least one
      # PR's stats were fetched — the digest never fails for want of them.
      def render_footer(totals)
        return nil unless totals

        measured = totals.measured_prs.to_i.positive?
        parts = []
        parts << "Lines +#{totals.additions.to_i}/-#{totals.deletions.to_i}" if measured
        parts << "PRs #{totals.prs.to_i}"
        parts << "Commits #{totals.commits.to_i}" if measured
        return nil if parts.empty?

        "#{FOOTER_DIVIDER}\n#{escape_mdv2(parts.join(' · '))}"
      end

      def render_project(project_name, items)
        category_sections = CATEGORY_ORDER.filter_map do |category, label|
          category_items = items.select { |entry| entry.category == category }
          next if category_items.empty?

          ([ "_#{label}_" ] + category_items.map { |entry| render_line(entry) }).join("\n")
        end
        return nil if category_sections.empty?

        ([ "*#{escape_mdv2(display_project(project_name))}*" ] + category_sections).join("\n")
      end

      # Title-case only the first letter so registered names like
      # "hive"/"screenote" read as "Hive"/"Screenote" in the section header
      # without mangling the rest of a multi-word slug.
      def display_project(project_name)
        project_name.to_s.sub(/\A./, &:upcase)
      end

      def blank?(value)
        value.to_s.strip.empty?
      end

      # Bound the model's overall summary on the raw text (before escaping) so
      # a cut can never split a MarkdownV2 `\x` escape pair.
      def truncate_overall_summary(text)
        truncate(text, MAX_OVERALL_SUMMARY_LENGTH)
      end

      def render_line(entry)
        item = entry.item
        summary = escape_mdv2(truncate_summary(entry.summary))
        label = escape_mdv2(truncate_label(item.display_label))
        target = item.pr_url.to_s
        link = target.empty? ? label : "[#{label}](#{escape_link_target(target)})"
        "• #{summary} — #{link}"
      end

      # Bound an untrusted, length-unbounded model summary so the escaped
      # line stays well under Telegram's 4096-char chunk boundary. Truncate
      # on the raw text (before escaping) so a cut can never split a `\x`
      # MarkdownV2 escape pair.
      def truncate_summary(text)
        truncate(text, MAX_SUMMARY_LENGTH)
      end

      # Bound the (attacker-influenceable) display label the same way as the
      # summary, on the raw text before escaping, so an overlong label can't
      # push the rendered link line past Telegram's chunk boundary.
      def truncate_label(text)
        truncate(text, MAX_LABEL_LENGTH)
      end

      def truncate(text, max_length)
        text = text.to_s
        return text if text.length <= max_length

        "#{text[0, max_length - 1].rstrip}…"
      end
      private_class_method :truncate

      def escape_link_target(url)
        url.to_s.gsub(RESERVED_LINK_TARGET) { "\\#{$1}" }
      end

      # Escape text destined for the inside of a MarkdownV2 code entity: only
      # '`' and '\' may be escaped there (see RESERVED_CODE_SPAN).
      def escape_code_span(text)
        text.to_s.gsub(RESERVED_CODE_SPAN) { "\\#{$1}" }
      end
    end
  end
end
