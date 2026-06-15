require "date"
require "hive/digest/categories"
require "hive/digest/categorizer"
require "hive/digest/window"

module Hive
  module Digest
    module Renderer
      # Shares the single ordered category set with the categorizer
      # (see Hive::Digest::Categories) so an accepted category can never
      # be silently dropped here for want of a render section.
      CATEGORY_ORDER = Categories::ORDERED

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
        summary = escape_mdv2(entry.summary)
        label = escape_mdv2(item.display_label)
        target = item.pr_url.to_s
        link = target.empty? ? label : "[#{label}](#{escape_link_target(target)})"
        "• #{summary} — #{link}"
      end

      def escape_link_target(url)
        url.to_s.gsub(RESERVED_LINK_TARGET) { "\\#{$1}" }
      end
    end
  end
end
