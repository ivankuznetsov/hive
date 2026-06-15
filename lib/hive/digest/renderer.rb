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

      RESERVED_MDV2 = /([\\_*\[\]()~`>#+\-=|{}.!])/

      # Inside a MarkdownV2 inline link destination only ')' and '\'
      # are special and must be escaped; every other URL character is
      # passed through untouched (Telegram MarkdownV2 spec). One
      # malformed URL would otherwise fail the whole day's send_message.
      RESERVED_LINK_TARGET = /([\\)])/

      module_function

      def render(grouped)
        sections = Array(grouped).filter_map do |project_name, items|
          render_project(project_name, Array(items))
        end

        return empty if sections.empty?

        sections.join("\n\n")
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

      def render_project(project_name, items)
        category_sections = CATEGORY_ORDER.filter_map do |category, label|
          category_items = items.select { |entry| entry.category == category }
          next if category_items.empty?

          ([ "_#{label}_" ] + category_items.map { |entry| render_line(entry) }).join("\n")
        end
        return nil if category_sections.empty?

        ([ "*#{escape_mdv2(project_name)}*" ] + category_sections).join("\n")
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
        text = text.to_s
        return text if text.length <= MAX_SUMMARY_LENGTH

        "#{text[0, MAX_SUMMARY_LENGTH - 1].rstrip}…"
      end

      # Bound the (attacker-influenceable) display label the same way as the
      # summary, on the raw text before escaping, so an overlong label can't
      # push the rendered link line past Telegram's chunk boundary.
      def truncate_label(text)
        text = text.to_s
        return text if text.length <= MAX_LABEL_LENGTH

        "#{text[0, MAX_LABEL_LENGTH - 1].rstrip}…"
      end

      def escape_link_target(url)
        url.to_s.gsub(RESERVED_LINK_TARGET) { "\\#{$1}" }
      end
    end
  end
end
