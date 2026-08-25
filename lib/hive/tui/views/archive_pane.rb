require "lipgloss"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Read-only archive projection. It consumes Snapshot's separate,
      # explicitly unfiltered archive payload so custom terminal stages and
      # retention-hidden tasks never leak into the ordinary grid.
      module ArchivePane
        TITLE = "Archive · all done tasks".freeze
        EMPTY = "(no archived tasks)".freeze
        HELP = "q/Esc close".freeze
        SLUG_WIDTH = 34
        PROJECT_WIDTH = 18
        AGE_WIDTH = 5

        module_function

        def render(model, width:)
          inner_width = [ width - 4, 20 ].max
          lines = [ Styles::HEADER.render(Format.truncate(TITLE, inner_width)), "" ]
          rows = archived_rows(model)
          if rows.empty?
            lines << Styles::HINT.render(EMPTY)
          else
            rows.each { |row| lines << render_row(row, inner_width) }
          end
          lines << ""
          lines << Styles::HINT.render(Format.truncate(HELP, inner_width))

          Styles::PANEL_BORDER
            .padding(1, 2)
            .width(inner_width)
            .render(lines.join("\n"))
        end

        def archived_rows(model)
          return [] unless model.snapshot

          model.snapshot.archive_rows
        end

        def render_row(row, inner_width)
          # Cell-aware padding (`ljust_cells`/`rjust_cells`), not String's
          # column-naive `ljust`/`rjust`: wide (CJK) characters occupy two
          # terminal cells, so padding to a character count overruns the
          # column and pushes later columns out of alignment.
          slug = Format.ljust_cells(row.slug.to_s, SLUG_WIDTH)
          project = Format.ljust_cells(row.project_name.to_s, PROJECT_WIDTH)
          age = Format.rjust_cells(Format.age(row.age_seconds), AGE_WIDTH)
          Format.truncate("#{slug} #{project} #{age}", inner_width)
        end
      end
    end
  end
end
