require "lipgloss"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module RedStatusDetail
        # Default footer for rows whose Enter has a meaningful action
        # (recover_review / error → autofix path).
        FOOTER = "[Enter] autofix / retry  [f] manual fix ($EDITOR)  [R] refresh diagnosis  [q] back".freeze
        # recover_execute (EXECUTE_STALE) rows have NO Enter affordance —
        # there is no auto-retry recipe (the operator must edit findings
        # or lower the pass counter). Advertising [Enter] would set up an
        # expectation that the no-op Enter then breaks. Drop the affordance
        # and keep [f]/[R]/[q]. See PR #84 review row 25.
        FOOTER_NO_ENTER = "[f] manual fix ($EDITOR)  [R] refresh diagnosis  [q] back".freeze

        module_function

        def footer_for(row)
          auto_action_available?(row) ? FOOTER : FOOTER_NO_ENTER
        end

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
          footer = Styles::CURSOR_HIGHLIGHT.render(truncate(footer_for(row), width))
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
            if diagnostic_retry_command(row)
              "A: Enter reruns the suggested recovery command. f opens the task folder in $EDITOR without changing state."
            elsif manual_fix?(row)
              "A: No autofix available. Press f to open the task folder in $EDITOR and repair the missing state."
            else
              "A: Enter clears the ERROR marker and reruns the task. f opens the worktree in $EDITOR without clearing the marker."
            end
          when "recover_execute"
            # EXECUTE_STALE has no auto-retry recipe — the operator must
            # edit findings or lower the pass counter before re-running.
            # The footer drops the [Enter] affordance for this row; mirror
            # the contract in the answer so the operator knows why.
            "A: No autofix available. Edit findings or lower the pass counter; press f to open the worktree in $EDITOR, then re-run."
          else
            "A: This row has no autofix action in the detail view."
          end
        end

        def auto_action_available?(row)
          return false if row.nil?
          return true if row.action_key.to_s == "recover_review"
          return false if row.action_key.to_s == "recover_execute"
          return true if row.action_key.to_s == "error" && diagnostic_retry_command(row)
          return true if row.action_key.to_s == "error" && row.marker.to_s == "error"

          false
        end

        def diagnostic_retry_command(row)
          suggested = row&.diagnostic && row.diagnostic["suggested_next_action"]
          return nil unless suggested.is_a?(Hash)
          return nil unless suggested["kind"].to_s == "retry"

          command = suggested["command"].to_s.strip
          command.empty? ? nil : command
        end

        def manual_fix?(row)
          suggested = row&.diagnostic && row.diagnostic["suggested_next_action"]
          suggested.is_a?(Hash) && suggested["kind"].to_s == "manual_fix"
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
