require "lipgloss"
require "hive/archive_filter"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Read-only archive projection. It intentionally uses the full
      # in-memory snapshot, not the grid's old-archive filter, so operators
      # can reach every 9-done task without a filesystem walk.
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

          model.snapshot.projects.flat_map do |project|
            project.rows.select { |row| row.stage == Hive::ArchiveFilter::ARCHIVE_STAGE_DIR }
          end
        end

        def render_row(row, inner_width)
          slug = Format.ljust_cells(row.slug.to_s, SLUG_WIDTH)
          project = Format.ljust_cells(row.project_name.to_s, PROJECT_WIDTH)
          age = Format.rjust_cells(Format.age(row.age_seconds), AGE_WIDTH)
          Format.truncate("#{slug} #{project} #{age}", inner_width)
        end
      end
    end
  end
end
