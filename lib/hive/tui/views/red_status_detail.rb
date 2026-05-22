require "lipgloss"
require "hive/agent_profiles"
require "hive/config"
require "hive/task"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module RedStatusDetail
        FOOTER = "[Enter] Recover   [o] Open in agent   [Esc] back".freeze
        AGENT_FALLBACK = "your project's development agent".freeze

        module_function

        def render(model)
          state = model.red_status_detail_state
          return "" if state.nil?

          row = state.row
          outer_width = [ model.cols.to_i - 2, 1 ].max
          bordered = outer_width >= 40
          inner_width = bordered ? [ outer_width - 2, 1 ].max : outer_width
          body_height = [ model.rows.to_i - 4, 1 ].max
          lines = []
          lines << Styles::HEADER.render(truncate("Task needs attention · #{safe(row.slug)}", inner_width))
          lines << ""
          lines << truncate("Project: #{safe(row.project_name)}", inner_width)
          lines << truncate("Stage: #{safe(row.stage)}", inner_width)
          lines.concat(wrapped("Why: #{summary_text(row)}", inner_width))
          lines << ""
          lines << Styles::HEADER.render(truncate("Actions", inner_width))
          lines << truncate("[Enter] Recover — re-run hive's automated recovery for this task", inner_width)
          lines << truncate("[o]     Open in agent — launch #{agent_label(row)} in the task worktree", inner_width)
          lines << ""
          lines << Styles::HINT.render(truncate(FOOTER, inner_width))

          visible = lines.first(body_height)
          body = Lipgloss.join_vertical(Lipgloss::TOP, *visible)
          return body unless bordered

          Styles::PANE_FOCUSED_BORDER.width(inner_width).render(body)
        end

        def summary_text(row)
          diagnostic = row.diagnostic || {}
          summary = safe(diagnostic["summary"]).strip
          return summary unless summary.empty?

          "Hive does not have a diagnosis yet — try Open in agent to inspect."
        end

        def agent_label(row)
          task = Hive::Task.new(row.folder.to_s)
          cfg = Hive::Config.load(task.project_root)
          agent_name = cfg.dig("execute", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(agent_name, cfg: cfg)
          File.basename(profile.bin.to_s)
        rescue Hive::ConfigError, Hive::AgentProfiles::UnknownAgent,
               Hive::AgentError, Hive::InvalidTaskPath, SystemCallError, IOError
          AGENT_FALLBACK
        end

        def wrapped(text, width)
          text = safe(text)
          return [ "" ] if text.empty?

          text.lines.flat_map { |line| wrap_line(line.chomp, width) }
        end

        def wrap_line(line, width)
          return [ "" ] if line.empty?
          return [ truncate(line, width) ] if width <= 8

          words = line.split(/\s+/)
          rows = []
          current = +""
          words.each do |word|
            if current.empty?
              current = word
            elsif "#{current} #{word}".length <= width
              current << " " << word
            else
              rows << truncate(current, width)
              current = word
            end
          end
          rows << truncate(current, width) unless current.empty?
          rows
        end

        def safe(value)
          Hive::Tui::Text.sanitize(value.to_s)
        end

        def truncate(string, width)
          Views::Format.truncate(string, width)
        end
      end
    end
  end
end
