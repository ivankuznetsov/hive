require "hive/digest/renderer"
require "hive/digest/window"
require "hive/digest/merged_pr/record"

module Hive
  module Digest
    module MergedPr
      module Renderer
        # Cap the "#<number> <title>" label the same way the sibling shipped
        # renderer caps its labels: bound the raw text BEFORE MarkdownV2
        # escaping so a Telegram chunk hard-cut can never land between a `\`
        # and the char it escapes (an invalid escape fails the whole send).
        # GitHub already caps titles at 256 chars, so this is a structural
        # guarantee rather than an incidental one.
        MAX_LABEL_LENGTH = Hive::Digest::Renderer::MAX_LABEL_LENGTH

        module_function

        def render(prs, date:)
          rows = Array(prs)
          blocks = [
            "Merged PR digest — #{escape(Window.parse_date(date).iso8601)}",
            "Total: #{rows.size} #{rows.size == 1 ? 'PR' : 'PRs'}"
          ]
          blocks.concat(grouped_sections(rows))
          blocks.join("\n\n")
        end

        def grouped_sections(prs)
          prs.group_by(&:repo).sort_by { |repo, _| repo }.map do |repo, rows|
            lines = [ "`#{escape_code(repo)} — #{rows.size}`" ]
            lines.concat(rows.sort_by { |pr| Window.parse_time(pr.mergedAt) }.map { |pr| render_line(pr) })
            lines.join("\n")
          end
        end

        def render_line(pr)
          label = Hive::Digest::Renderer.truncate_label("##{pr.number} #{pr.title}")
          link = pr.url.to_s.empty? ? escape(label) : "[#{escape(label)}](#{escape_link(pr.url)})"
          "#{escape('•')} #{link} #{escape('—')} #{suffix(pr)}"
        end

        def suffix(pr)
          if pr.hive_slug.to_s.empty?
            escape(pr.author)
          else
            escape("Hive task matched")
          end
        end

        def escape(text)
          Hive::Digest::Renderer.escape_mdv2(text)
        end

        def escape_link(url)
          Hive::Digest::Renderer.escape_link_target(url)
        end

        # The repo header wraps the name in a `` `…` `` code entity, where only
        # `` ` `` and `\` may be escaped — using the general escape_mdv2 there
        # would render literal backslashes on the near-universal `-`/`.`/`_`
        # repo names and risk a MarkdownV2 400 that fails the whole send.
        def escape_code(text)
          Hive::Digest::Renderer.escape_code_span(text)
        end
      end
    end
  end
end
