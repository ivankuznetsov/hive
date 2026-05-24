require "lipgloss"
require "hive/usage_db"
require "hive/tui/styles"
require "hive/tui/views/format"
require "hive/tui/views/usage_footer"

module Hive
  module Tui
    module Views
      module TokenStats
        AGENTS = %i[claude codex pi].freeze
        BUCKETS = %i[today 7d 30d all].freeze
        HEADER = [ "agent", "today", "7d", "30d", "all" ].freeze
        HELP = "← → drill • ↑ ↓ select • q close".freeze

        module_function

        def render(model, aggregate:)
          width = [ model.cols.to_i - 2, 40 ].max
          inner_width = [ width - 4, 20 ].max
          lines = [
            Styles::HEADER.render(Format.truncate("Token usage · scope: #{scope_label(model.token_stats_state)}", inner_width)),
            "",
            table(aggregate, inner_width),
            "",
            Styles::HINT.render(Format.truncate(HELP, inner_width))
          ]

          Styles::PANEL_BORDER
            .padding(1, 2)
            .width(inner_width)
            .render(lines.join("\n"))
        end

        def table(aggregate, inner_width)
          rows = [ HEADER ]
          AGENTS.each do |agent|
            rows << row_for(agent.to_s, aggregate.fetch(:agents, {}).fetch(agent, zero_buckets))
          end
          rows << row_for("TOTAL", aggregate.fetch(:total, zero_buckets))
          widths = column_widths(rows, inner_width)
          rows.map { |row| render_row(row, widths) }.join("\n")
        end

        def row_for(label, buckets)
          [ label ] + BUCKETS.map { |bucket| UsageFooter.format_usage(buckets.fetch(bucket, zero_usage)) }
        end

        def column_widths(rows, inner_width)
          natural = HEADER.each_index.map do |idx|
            rows.map { |row| row[idx].to_s.length }.max || 1
          end
          separators = HEADER.size - 1
          overflow = natural.sum + separators - inner_width
          return natural if overflow <= 0

          natural.each_index.reverse_each do |idx|
            next if idx.zero?

            shrink = [ overflow, natural[idx] - 6 ].min
            next if shrink <= 0

            natural[idx] -= shrink
            overflow -= shrink
            break if overflow <= 0
          end
          natural
        end

        def render_row(row, widths)
          row.each_with_index.map do |cell, idx|
            text = Format.truncate(cell.to_s, widths[idx])
            idx.zero? ? text.ljust(widths[idx]) : text.rjust(widths[idx])
          end.join(" ")
        end

        def scope_label(state)
          return "all projects" if state.nil? || state.scope_level == :all
          return state.project_slug.to_s if state.scope_level == :project

          [ state.project_slug, state.task_slug ].compact.join(" / ")
        end

        def zero_buckets
          Hive::UsageDb.zero_buckets
        end

        def zero_usage
          Hive::UsageDb.zero_usage
        end
      end
    end
  end
end
