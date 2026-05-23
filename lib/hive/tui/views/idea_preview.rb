require "hive/tui/model"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Full-screen, read-only task info panel. All file I/O happens in
      # BubbleModel when the panel opens; this view only renders the
      # captured InfoPanelState.
      module IdeaPreview
        DISMISS_HINT = "press q / Esc / i to close".freeze
        DIVIDER = "─".freeze
        # Common label-column width for the `created_at`, `folder`, and
        # `latest log` rows. Computed from the longest label so a future
        # rename (e.g. `working_dir` at 11 chars) does not silently
        # collapse the value-column gap to a single space.
        LABEL_COL = [ "created_at", "folder", "latest log" ].map(&:length).max + 2

        module_function

        def render(model, width: model.cols.to_i, height: model.rows.to_i - 1)
          state = model.info_panel_state
          return "" if state.nil?

          usable = [ width.to_i, 1 ].max
          max_rows = [ height.to_i, 1 ].max
          content_capacity = [ max_rows - 1, 0 ].max

          base = base_lines(state, usable)
          extra = extra_lines(state, usable)
          rows = fit_panel_lines(base, extra, content_capacity, usable)
          rows << "" while rows.length < content_capacity
          rows << Styles::HINT.render(truncate(DISMISS_HINT.rjust(usable), usable))
          rows.join("\n")
        end

        def base_lines(state, width)
          [
            Styles::HINT.render(truncate(header_line(state, width), width)),
            Styles::HINT.render(DIVIDER * width),
            field_line("created_at", present(state.created_at) ? state.created_at : "(unknown)", width),
            field_line("folder", present(state.folder_path) ? state.folder_path : "(unknown)", width),
            field_line("latest log", present(state.latest_log_path) ? state.latest_log_path : "(none)", width),
            "",
            Styles::HINT.render(truncate("Original idea", width)),
            Styles::HINT.render(truncate(DIVIDER * "Original idea".length, width)),
            *wrapped_body(state.original_text.to_s, width)
          ]
        end

        def extra_lines(state, width)
          return [] unless present(state.stage_extra)

          title = extra_title(state)
          [
            "",
            Styles::HINT.render(truncate(title, width)),
            Styles::HINT.render(DIVIDER * [ title.length, width ].min),
            *wrapped_body(state.stage_extra.to_s, width)
          ]
        end

        def fit_panel_lines(base, extra, capacity, width)
          return [] if capacity <= 0
          return truncate_rows(base, capacity, width) if base.length >= capacity

          remaining = capacity - base.length
          base + truncate_rows(extra, remaining, width)
        end

        def truncate_rows(rows, capacity, width)
          return [] if capacity <= 0
          return rows if rows.length <= capacity

          visible = rows.first(capacity)
          visible[-1] = truncate(with_ellipsis(visible[-1].to_s), width)
          visible
        end

        # Append the truncation `…` indicator, taking care to insert it
        # before any trailing ANSI reset escape so a styled line (e.g.
        # the dim divider rendered via `Styles::HINT.render(DIVIDER * …)`)
        # keeps the ellipsis inside the same style run. Without this,
        # the indicator pops outside the dim style on real terminals.
        def with_ellipsis(line)
          if (match = line.match(/\A(.*?)(\e\[[\d;]*m)\z/m))
            prefix = match[1].sub(/\s+\z/, "")
            return line if prefix.end_with?("…")

            "#{prefix}…#{match[2]}"
          else
            stripped = line.sub(/\s+\z/, "")
            stripped.end_with?("…") ? stripped : "#{stripped}…"
          end
        end

        def header_line(state, width)
          stage = "[stage: #{state.stage}]"
          prefix = "Info: #{state.slug}"
          gap = width - prefix.length - stage.length
          gap >= 2 ? "#{prefix}#{" " * gap}#{stage}" : "#{prefix}  #{stage}"
        end

        def field_line(label, value, width)
          gap = [ LABEL_COL - label.length, 1 ].max
          truncate("#{label}:#{' ' * gap}#{value}", width)
        end

        def extra_title(state)
          case state.stage.to_s
          when "2-brainstorm" then "brainstorm.md"
          when "3-plan" then "plan.md"
          when "4-execute" then "execute log"
          else "details"
          end
        end

        def wrapped_body(text, width)
          return [] if text.empty?

          wrap_text(text, width).map { |line| truncate(line, width) }
        end

        # Intentional local copy of NewIdeaPrompt's simple chunking shape.
        # NewIdeaPrompt's helper is cursor-aware and attachment-aware;
        # extracting it would widen this read-only view change.
        def chunk_buffer(buffer, capacity)
          return [ "" ] if buffer.empty?

          chunks = []
          offset = 0
          while offset < buffer.length
            chunks << buffer[offset, capacity].to_s
            offset += capacity
          end
          chunks
        end

        def wrap_text(text, width)
          capacity = [ width.to_i, 1 ].max
          text.each_line(chomp: true).flat_map do |line|
            chunk_buffer(line, capacity)
          end
        end

        def truncate(line, width)
          Views::Format.truncate(line, width.to_i)
        end

        def present(value)
          !value.nil? && !value.to_s.empty?
        end
      end
    end
  end
end
