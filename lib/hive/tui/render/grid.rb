require "curses"
require "hive"
require "hive/commands/status"
require "hive/tui/render/palette"

module Hive
  module Tui
    module Render
      # Status grid renderer. Draws one frame per call against the
      # snapshot under the current `grid_state` (scope + filter applied,
      # cursor highlighted). Column widths match
      # `Hive::Commands::Status#render_project` (slug 36, action label
      # 24, suggested_command verbatim, age right-aligned) so a side-by-
      # side comparison of `hive status` and `hive tui` lines up.
      #
      # Curses calls only run inside method bodies — `require`-ing this
      # file from a non-tty test process never initialises the screen.
      class Grid
        SLUG_WIDTH = 36
        LABEL_WIDTH = 24

        def draw(snapshot, grid_state)
          Curses.erase
          visible = grid_state.visible_snapshot(snapshot)
          row_cursor = 0

          row_cursor = draw_header(snapshot, grid_state, row_cursor)

          if visible.projects.empty?
            draw_centered_message("(no projects registered; run `hive init <path>`)", row_cursor)
          else
            row_cursor = draw_projects(visible, grid_state, row_cursor)
            draw_filter_empty_message(grid_state, row_cursor) if visible.rows.empty? && grid_state.filter
          end

          draw_status_line(grid_state)
          Curses.refresh
        end

        private

        # The header is one line: `hive tui  scope=<n>  filter=<s>
        # generated_at=<t>`. Stalled-poll annotation comes later (U7);
        # we leave a stable layout so adding it later is additive.
        def draw_header(snapshot, grid_state, row_cursor)
          scope_label = grid_state.scope.zero? ? "all" : grid_state.scope.to_s
          filter_label = grid_state.filter.to_s.empty? ? "-" : grid_state.filter
          generated_at = snapshot.generated_at || "-"
          line = "hive tui  scope=#{scope_label}  filter=#{filter_label}  generated_at=#{generated_at}"

          with_attr(Curses::A_BOLD) { put(row_cursor, 0, line) }
          row_cursor + 2
        end

        def draw_projects(visible, grid_state, row_cursor)
          visible.projects.each_with_index do |project, project_idx|
            row_cursor = draw_project(project, project_idx, grid_state, row_cursor)
          end
          row_cursor
        end

        def draw_project(project, project_idx, grid_state, row_cursor)
          with_attr(Curses::A_BOLD) { put(row_cursor, 0, project.name.to_s) }
          row_cursor += 1

          if project.error
            put(row_cursor, 2, "error: #{project.error}")
            return row_cursor + 2
          end

          if project.rows.empty?
            put(row_cursor, 2, "no active tasks")
            return row_cursor + 2
          end

          row_cursor = draw_grouped_rows(project, project_idx, grid_state, row_cursor)
          row_cursor + 1
        end

        # Groups by action_label in `Status::ACTION_LABEL_ORDER`; unknown
        # labels sort last so a future label addition still renders.
        def draw_grouped_rows(project, project_idx, grid_state, row_cursor)
          ordered = order_labels(project.rows.map(&:action_label).uniq)
          row_idx_in_project = 0
          ordered.each do |label|
            group = project.rows.select { |r| r.action_label == label }
            next if group.empty?

            put(row_cursor, 2, label)
            row_cursor += 1
            group.each do |row|
              draw_task_row(row, row_cursor, project_idx, row_idx_in_project, grid_state)
              row_cursor += 1
              row_idx_in_project += 1
            end
          end
          row_cursor
        end

        def order_labels(labels)
          known = Hive::Commands::Status::ACTION_LABEL_ORDER
          labels.sort_by { |label| known.index(label) || known.length }
        end

        def draw_task_row(row, screen_row, project_idx, row_idx, grid_state)
          highlighted = grid_state.cursor == [ project_idx, row_idx ]
          indicator = highlighted ? ">" : " "
          slug = row.slug.to_s.ljust(SLUG_WIDTH)
          label = row.action_label.to_s.ljust(LABEL_WIDTH)
          command = row.suggested_command || "-"
          age = format_age(row.age_seconds)

          line = "#{indicator} #{slug} #{label} #{command} #{age}"
          attrs = Curses.color_pair(Palette.for_action_key(row.action_key))
          attrs |= Curses::A_REVERSE if highlighted
          with_attr(attrs) { put(screen_row, 2, line) }
        end

        # Single-place humaniser so the grid line matches `hive status`.
        # Mirrors Status#humanise_age for the same input shape.
        def format_age(age_seconds)
          seconds = age_seconds.to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600
          return "#{seconds / 3600}h" if seconds < 86_400

          "#{seconds / 86_400}d"
        end

        def draw_filter_empty_message(grid_state, row_cursor)
          draw_centered_message(%((no tasks matching "#{grid_state.filter}")), row_cursor + 1)
        end

        # Bottom-line status: flash message takes priority over the help
        # hint so user feedback always wins. The flash decays in
        # GridState#flash_active?, which is the contract this honours.
        def draw_status_line(grid_state)
          row = Curses.lines - 1
          Curses.setpos(row, 0)
          Curses.clrtoeol
          if grid_state.flash_active?
            attrs = Curses.color_pair(Palette::PAIR_FLASH) | Curses::A_BOLD
            with_attr(attrs) { Curses.addstr(grid_state.flash_message.to_s) }
          else
            Curses.addstr("[?] help  [/] filter  [q] quit")
          end
        end

        def draw_centered_message(message, row)
          col = [ (Curses.cols - message.length) / 2, 0 ].max
          put(row, col, message)
        end

        def put(row, col, text)
          Curses.setpos(row, col)
          Curses.addstr(text.to_s)
        end

        def with_attr(attrs)
          Curses.attron(attrs)
          yield
        ensure
          Curses.attroff(attrs)
        end
      end
    end
  end
end
