require "lipgloss"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module RedStatusDetail
        FOOTER = "[Enter] autofix / retry  [f] manual fix ($EDITOR)  [R] refresh diagnosis  [q] back".freeze

        module_function

        def render(model)
          state = model.red_status_detail_state
          return "" if state.nil?

          row = state.row
          width = [ model.cols.to_i - 1, 1 ].max
          body_height = [ model.rows.to_i - 2, 1 ].max
          lines = []
          lines << Styles::HEADER.render(truncate("Red status · #{safe(row.slug)}", width))
          lines << ""
          lines << truncate("Project: #{safe(row.project_name)}", width)
          lines << truncate("Stage: #{safe(row.stage)}", width)
          lines << truncate("Marker: #{safe(row.marker)} #{attrs_text(row)}".strip, width)
          lines << truncate("Status: #{safe(row.action_label)}", width)
          lines << ""
          lines.concat(question_answer_lines(row, width))
          lines << ""
          lines.concat(artifact_lines(row, width))
          lines << Styles::HINT.render(truncate("Refreshing diagnosis...", width)) if state.refreshing

          visible = lines.first(body_height)
          footer = Styles::CURSOR_HIGHLIGHT.render(truncate(FOOTER, width))
          Lipgloss.join_vertical(Lipgloss::TOP, *visible, footer)
        end

        def question_answer_lines(row, width)
          diagnostic = row.diagnostic || {}
          summary = safe(diagnostic["summary"])
          detail = safe(diagnostic["detail"])
          summary = "No local diagnostic is available yet." if summary.empty?
          detail = "Press R to ask the configured development agent for a fresh diagnosis." if detail.empty?

          [
            Styles::HEADER.render(truncate("Q: Why is this red?", width)),
            *wrapped("A: #{summary}", width),
            *wrapped(detail, width),
            "",
            Styles::HEADER.render(truncate("Q: What can Hive do next?", width)),
            *wrapped(action_answer(row), width)
          ]
        end

        def action_answer(row)
          case row.action_key.to_s
          when "recover_review"
            "A: Enter runs the existing review recovery path. f opens the worktree in $EDITOR without clearing the marker."
          when "error"
            "A: Enter clears the ERROR marker and reruns the task. f opens the worktree in $EDITOR without clearing the marker."
          else
            "A: This row has no autofix action in the detail view."
          end
        end

        def artifact_lines(row, width)
          diagnostic = row.diagnostic || {}
          paths = Array(diagnostic["artifact_paths"])
          return [ Styles::HINT.render(truncate("Artifacts: none", width)) ] if paths.empty?

          lines = [ Styles::HEADER.render(truncate("Artifacts", width)) ]
          paths.each { |path| lines << truncate("- #{safe(path)}", width) }
          lines
        end

        def attrs_text(row)
          (row.attrs || {}).map { |key, value| "#{safe(key)}=#{safe(value)}" }.join(" ")
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
