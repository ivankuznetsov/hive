require "lipgloss"
require "hive/tui/model"
require "hive/tui/red_status_detail_keys"
require "hive/tui/red_status_detail_layout"
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
        AGENT_FALLBACK = Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK

        MARKER_SUMMARY_PATTERN = /\A[A-Z][A-Z0-9_]+(?:\s+[a-z_]+=\S+)+\z/

        MIN_LOG_PANEL_ROWS = Hive::Tui::RedStatusDetailLayout::MIN_LOG_PANEL_ROWS
        MAX_LOG_PANEL_ROWS = Hive::Tui::RedStatusDetailLayout::MAX_LOG_PANEL_ROWS

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
          body_lines << Styles::HEADER.render(truncate("Task needs attention · #{identity_label(row)}", inner_width))
          body_lines << ""
          body_lines << truncate("Project: #{safe(row.project_name)}", inner_width)
          body_lines << truncate("Stage: #{safe(row.stage)}", inner_width)
          body_lines.concat(wrapped("Why: #{summary_text(row)}", inner_width))
          body_lines << ""
          body_lines << Styles::HEADER.render(truncate("Actions", inner_width))
          body_lines.concat(action_bar(state.agent_label, inner_width).lines.map(&:chomp))

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

          ACTION_KEYS.map { |entry| Styles::HINT.render(truncate(entry[:footer], inner_width)) }
        end

        def flash_line_for(model, inner_width)
          return nil unless model.respond_to?(:flash_active?) && model.flash_active?

          text = safe(model.flash.to_s).strip
          return nil if text.empty?

          Styles::HINT.render(truncate(text, inner_width))
        end

        def action_bar(agent_label, width)
          wrap_action_chips(action_chips(agent_label), width).join("\n")
        end

        def action_chips(agent_label)
          label = safe(agent_label || AGENT_FALLBACK)
          [
            [ "[Enter] Recover — re-run hive's automated recovery for this task", true ],
            [ "[o]     Open in agent — launch #{label} in the task worktree", false ]
          ]
        end

        def wrap_action_chips(chips, width)
          max_width = [ width.to_i, 1 ].max
          rendered = chips.map do |label, primary|
            text = truncate(label, max_width)
            primary ? Styles::ACTION_CHIP_PRIMARY.render(text) : Styles::ACTION_CHIP_MUTED.render(text)
          end

          lines = []
          current = +""
          rendered.each do |chip|
            candidate = current.empty? ? chip : "#{current} #{chip}"
            if candidate.length <= max_width
              current = candidate
            else
              lines << current unless current.empty?
              current = chip
            end
          end
          lines << current unless current.empty?
          lines
        end

        def header_bar(row, width)
          prefix = "RED · "
          project_stage = "#{safe(row.project_name)}/#{safe(row.stage)}"
          slug = identity_label(row)
          path = safe(row.worktree_path || row.folder)

          line = header_line(prefix, project_stage, slug, path, width)
          Styles::RECOVERY_HEADER_STYLE.render(line)
        end

        # Single fall-through axis: try the longest stem that still fits
        # and append a truncated final field.
        def header_line(prefix, project_stage, slug, path, width)
          first = "#{prefix}#{project_stage}"
          with_slug = "#{first} · #{slug}"
          with_path_prefix = "#{with_slug} · "

          candidates = [
            [ with_path_prefix, path ],
            [ "#{first} · ", slug ],
            [ prefix, project_stage ]
          ]

          candidates.each do |stem, value|
            next unless stem.length < width

            return stem + truncate(value, width - stem.length)
          end

          truncate(first, width)
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
          title_text = "Log · last #{visible.length} of #{lines.length} lines " \
                       "(#{Hive::Tui::RedStatusDetailLayout::LOG_SNAPSHOT_BACKBUFFER_LABEL}, snapshot)"
          title = Styles::HEADER.render(truncate(title_text, outer_width))
          border = Styles::PANEL_BORDER.width(content_width).render(body)
          Lipgloss.join_vertical(Lipgloss::TOP, title, border)
        end

        def clamp_log_offset(offset, line_count, capacity)
          max = [ line_count - capacity, 0 ].max
          [ [ offset.to_i, 0 ].max, max ].min
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

        def summary_text(row)
          diagnostic = row.diagnostic || {}
          summary = safe(diagnostic["summary"]).strip
          return missing_summary_fallback if summary.empty?
          return missing_summary_fallback if summary.match?(MARKER_SUMMARY_PATTERN)

          summary
        end

        def identity_label(row)
          name = safe(row.display_name).strip
          name = safe(row.slug) if name.empty?
          row.id ? "##{row.id} #{name} (#{safe(row.slug)})" : "#{name} (#{safe(row.slug)})"
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
