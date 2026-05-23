require "lipgloss"
require "hive/tui/model"
require "hive/tui/red_status_detail_keys"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/log_tail"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module RedStatusDetail
        # Shared single-source-of-truth for the detail screen's action
        # key list lives in `Hive::Tui::RedStatusDetailKeys` so both
        # this view (footer) and `KeyMap` (refusal-flash hint) read the
        # same data without the view module exposing rendering surface.
        ACTION_KEYS = Hive::Tui::RedStatusDetailKeys::ACTION_KEYS
        FOOTER = Hive::Tui::RedStatusDetailKeys::FOOTER
        # Re-export so external readers (tests, KeyMap) can pin against
        # the canonical fallback string without depending on Model
        # internals.
        AGENT_FALLBACK = Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK

        # Detect a `TaskAction#marker_summary`-style string (uppercase
        # marker name followed by at least one `key=value` attr pair)
        # that leaked into diagnostic["summary"] from an older artifact.
        # Requires the attrs portion so a legitimate bare upper-case
        # verdict like `ABORTED` or a real sentence is not mistakenly
        # treated as debug copy. See plan Unit 1.
        MARKER_SUMMARY_PATTERN = /\A[A-Z][A-Z0-9_]+(?:\s+[a-z_]+=\S+)+\z/

        MIN_LOG_PANEL_ROWS = 4
        MAX_LOG_PANEL_ROWS = 12

        module_function

        def render(model)
          state = model.red_status_detail_state
          return "" if state.nil?

          row = state.row
          header_width = [ model.cols.to_i - 1, 1 ].max
          outer_width = [ model.cols.to_i - 2, 1 ].max
          bordered = model.cols.to_i >= 40
          inner_width = bordered ? [ outer_width - 2, 1 ].max : outer_width
          body_height = [ model.rows.to_i - 5, 1 ].max
          footer_lines = footer_lines_for(inner_width)
          flash_line = flash_line_for(model, inner_width)

          # Reserve footer and optional flash rows outside the content
          # trim so action keys remain visible on very short terminals.
          reserved = footer_lines.size + 1 # footer + leading blank
          reserved += 1 if flash_line
          inner_body_height = [ body_height - reserved, 1 ].max
          body_lines = composed_content_lines(state, inner_width, inner_body_height)
          visible = body_lines.first(inner_body_height)
          visible << ""
          visible << flash_line if flash_line
          visible.concat(footer_lines)
          body = Lipgloss.join_vertical(Lipgloss::TOP, *visible)
          panel = if bordered
                    Styles::PANE_FOCUSED_BORDER.width(inner_width).render(body)
                  else
                    body
                  end

          Lipgloss.join_vertical(Lipgloss::TOP, header_bar(row, header_width), panel)
        end

        def composed_content_lines(state, inner_width, inner_body_height)
          row = state.row
          body_lines = []
          body_lines << Styles::HEADER.render(truncate("Task needs attention · #{safe(row.slug)}", inner_width))
          body_lines << ""
          body_lines << truncate("Project: #{safe(row.project_name)}", inner_width)
          body_lines << truncate("Stage: #{safe(row.stage)}", inner_width)
          body_lines.concat(wrapped("Why: #{summary_text(row)}", inner_width))
          body_lines << ""
          body_lines << Styles::HEADER.render(truncate("Actions", inner_width))
          body_lines << truncate("[Enter] Recover — re-run hive's automated recovery for this task", inner_width)
          body_lines << truncate("[o]     Open in agent — launch #{safe(state.agent_label || AGENT_FALLBACK)} in the task worktree", inner_width)

          append_artifacts(body_lines, artifacts_block(row, inner_width), inner_body_height)
          append_log_preview(body_lines, state, inner_width, inner_body_height)

          body_lines
        end

        def append_log_preview(body_lines, state, inner_width, inner_body_height)
          return if Array(state.log_lines).empty?

          available = inner_body_height - body_lines.length
          return if available < MIN_LOG_PANEL_ROWS + 2

          height_budget = [ available - 2, MAX_LOG_PANEL_ROWS ].min
          if (panel = log_panel(state, inner_width, height_budget))
            body_lines << ""
            body_lines.concat(panel.lines.map(&:chomp))
          end
        end

        def append_artifacts(body_lines, artifacts_block, inner_body_height)
          return unless artifacts_block

          artifact_lines = artifacts_block.lines.map(&:chomp)
          return if body_lines.length + artifact_lines.length + 1 > inner_body_height

          body_lines << ""
          body_lines.concat(artifact_lines)
        end


        def footer_lines_for(inner_width)
          return [ Styles::HINT.render(FOOTER) ] if FOOTER.length <= inner_width

          # Narrow terminals: stack one key per line so a `[Esc] back`
          # affordance never gets truncated off the end of a single
          # joined footer line.
          ACTION_KEYS.map { |entry| Styles::HINT.render(truncate(entry[:footer], inner_width)) }
        end

        # Surface `model.flash` on the detail screen so a refusal flash
        # fired by KeyMap (e.g., `s` muscle-memory drift) is observable
        # without backing out to the grid. Without this, the explicit-
        # refusal contract documented in `red_status_detail_message` is
        # invisible until the operator dismisses the screen.
        def flash_line_for(model, inner_width)
          return nil unless model.respond_to?(:flash_active?) && model.flash_active?

          text = safe(model.flash.to_s).strip
          return nil if text.empty?

          Styles::HINT.render(truncate(text, inner_width))
        end

        def header_bar(row, width)
          prefix = "RED · "
          project_stage = "#{safe(row.project_name)}/#{safe(row.stage)}"
          slug = safe(row.slug)
          path = safe(row.worktree_path || row.folder)

          line = header_line(prefix, project_stage, slug, path, width)
          Styles::RECOVERY_HEADER_BAR.render(line)
        end

        def header_line(prefix, project_stage, slug, path, width)
          first = "#{prefix}#{project_stage}"
          with_slug = "#{first} · #{slug}"
          with_path_prefix = "#{with_slug} · "

          if with_path_prefix.length < width
            return with_path_prefix + truncate(path, width - with_path_prefix.length)
          end

          if "#{first} · ".length < width
            return "#{first} · " + truncate(slug, width - "#{first} · ".length)
          end

          return truncate(first, width) if width < prefix.length

          prefix + truncate(project_stage, width - prefix.length)
        end

        def log_panel(state, outer_width, height_budget)
          lines = Array(state.log_lines)
          return nil if lines.empty?

          content_width = [ outer_width - 2, 1 ].max
          capacity = [ height_budget.to_i - 2, 1 ].max
          offset = clamp_log_offset(state.log_scroll_offset, lines.length, capacity)
          end_index = [ lines.length - offset, 0 ].max
          start_index = [ end_index - capacity, 0 ].max
          visible = lines[start_index...end_index] || []
          body = visible.map { |line| truncate(safe(Hive::Tui::LogTail::Formatter.format(line)), content_width) }.join("\n")
          title = Styles::HEADER.render(truncate("Log · last #{visible.length} of #{lines.length} lines", outer_width))
          border = Styles::PANEL_BORDER.width(content_width).render(body)
          Lipgloss.join_vertical(Lipgloss::TOP, title, border)
        end

        def clamp_log_offset(offset, line_count, capacity)
          max = [ line_count - capacity, 0 ].max
          [[ offset.to_i, 0 ].max, max].min
        end

        def reason_meta(row)
          marker_attrs = attrs_text(row)
          marker = [ "Marker: #{safe(row.marker)}", marker_attrs ].reject(&:empty?).join(" ")
          "#{marker}  ·  Status: #{safe(row.action_label)}"
        end

        def artifacts_block(row, width)
          diagnostic = row.diagnostic || {}
          paths = Array(diagnostic["artifact_paths"]).map { |path| safe(path).strip }.reject(&:empty?)
          return nil if paths.empty?

          lines = [ Styles::HEADER.render(truncate("Artifacts", width)) ]
          paths.first(5).each do |path|
            lines << Styles::HINT.render(truncate("  • #{path}", width))
          end
          if paths.length > 5
            lines << Styles::HINT.render(truncate("  • … (#{paths.length - 5} more)", width))
          end
          lines.join("\n")
        end


        def attrs_text(row)
          (row.attrs || {}).map { |key, value| "#{safe(key)}=#{safe(value)}" }.join(" ")
        end

        def summary_text(row)
          diagnostic = row.diagnostic || {}
          summary = safe(diagnostic["summary"]).strip
          return missing_summary_fallback if summary.empty?
          # marker_summary leaked from TaskAction: strip and use the
          # plain-English fallback rather than dump debug copy.
          return missing_summary_fallback if summary.match?(MARKER_SUMMARY_PATTERN)

          summary
        end

        def missing_summary_fallback
          "Hive does not have a diagnosis yet — try Open in agent to inspect."
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
