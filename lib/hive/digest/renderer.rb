require "hive/digest/london_window"

module Hive
  module Digest
    module Renderer
      BRAND = "Hive".freeze
      HASHTAG = "#Digest".freeze
      FOOTER_DIVIDER = "──────────".freeze
      MAX_ESCAPED_LINE_LENGTH = 2_800
      RESERVED_MDV2 = /([\\_*\[\]()~`>#+\-=|{}.!])/
      RESERVED_LINK_TARGET = /([\\)])/
      RESERVED_CODE_SPAN = /([\\`])/

      module_function

      def render(changelog:, date:, stats:, warnings: [])
        blocks = [ header(date), render_counts(changelog, stats) ]
        changelog.projects.each do |project|
          blocks << render_project(project, stats.by_repository.fetch(project.repository.target.repository))
        end
        blocks << render_warnings(warnings) unless Array(warnings).empty?
        blocks << render_footer(stats.overall)
        blocks.join("\n\n")
      end

      def escape_mdv2(text)
        text.to_s.gsub(RESERVED_MDV2) { "\\#{$1}" }
      end

      def escape_link_target(url)
        url.to_s.gsub(RESERVED_LINK_TARGET) { "\\#{$1}" }
      end

      def escape_code_span(text)
        text.to_s.gsub(RESERVED_CODE_SPAN) { "\\#{$1}" }
      end

      def header(date)
        "*#{escape_mdv2(BRAND)}* #{escape_mdv2(HASHTAG)}\n#{escape_mdv2(format_date(date))}"
      end

      def format_date(date)
        LondonWindow.parse_date(date).strftime("%a, %-d %B %Y")
      end

      def render_counts(changelog, stats)
        escape_mdv2("Projects #{changelog.projects.size} · PRs #{stats.overall.pr_count}")
      end

      def render_project(project, aggregate)
        repository = project.repository.target.repository
        blocks = [ "*#{escape_mdv2(repository)}*" ]
        blocks << wrap_plain(project.significance).join("\n")
        blocks << escape_mdv2(metric_line(aggregate))
        project.pull_requests.each { |generated_pr| blocks << render_pr(generated_pr) }
        blocks.join("\n")
      end

      def render_pr(generated_pr)
        pr = generated_pr.pull_request
        link = "[PR #{escape_mdv2("##{pr.number}")}](#{escape_link_target(pr.url)})"
        title_lines = wrap_plain(pr.title, first_prefix: "", continuation_prefix: "  ")
        bullet_lines = generated_pr.bullets.flat_map do |bullet|
          wrap_plain(bullet.text, first_prefix: "• ", continuation_prefix: "  ")
        end
        ([ link ] + title_lines + bullet_lines).join("\n")
      end

      def render_warnings(warnings)
        lines = [ "*#{escape_mdv2('Warnings')}*" ]
        Array(warnings).each do |warning|
          lines.concat(wrap_plain(warning.message, first_prefix: "⚠️ ", continuation_prefix: "  "))
        end
        lines.join("\n")
      end

      def render_footer(aggregate)
        "#{FOOTER_DIVIDER}\n#{escape_mdv2(metric_line(aggregate))}"
      end

      def metric_line(aggregate)
        metrics = aggregate.metrics
        additions = metrics.fetch(:additions)
        deletions = metrics.fetch(:deletions)
        commits = metrics.fetch(:commits)
        parts = line_metric_parts(additions, deletions)
        parts << "PRs #{aggregate.pr_count}"
        parts << "Commits #{commits.value}#{partial_label(commits)}" unless commits.value.nil?
        parts.join(" · ")
      end

      def line_metric_parts(additions, deletions)
        if !additions.value.nil? && !deletions.value.nil?
          partial = additions.partial? || deletions.partial?
          [ "Lines +#{additions.value}/-#{deletions.value}#{partial ? ' (partial)' : ''}" ]
        else
          parts = []
          parts << "Additions +#{additions.value}#{partial_label(additions)}" unless additions.value.nil?
          parts << "Deletions -#{deletions.value}#{partial_label(deletions)}" unless deletions.value.nil?
          parts
        end
      end

      def partial_label(metric)
        metric.partial? ? " (partial)" : ""
      end

      def wrap_plain(text, first_prefix: "", continuation_prefix: "")
        raw_lines = text.to_s.split("\n", -1)
        segments = raw_lines.flat_map { |line| escaped_segments(line) }
        segments = [ "" ] if segments.empty?
        segments.each_with_index.map do |segment, index|
          prefix = index.zero? ? first_prefix : continuation_prefix
          "#{escape_mdv2(prefix)}#{escape_mdv2(segment)}"
        end
      end

      def escaped_segments(text)
        return [ "" ] if text.empty?

        segments = []
        current = +""
        escaped_length = 0
        graphemes(text).each do |grapheme|
          cost = escape_mdv2(grapheme).length
          if escaped_length.positive? && escaped_length + cost > MAX_ESCAPED_LINE_LENGTH
            segments << current
            current = +""
            escaped_length = 0
          end
          current << grapheme
          escaped_length += cost
        end
        segments << current unless current.empty?
        segments
      end

      def graphemes(text)
        text.scan(/\X/)
      end
      private_class_method :graphemes
    end
  end
end
