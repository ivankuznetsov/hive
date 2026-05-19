require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Bottom prompt shown when the operator starts a new idea from
      # `★ All projects`. Creating a task has to target one concrete project,
      # so this picker makes that choice explicit before the title composer.
      module NewIdeaProjectPicker
        MAX_VISIBLE_PROJECTS = 6

        module_function

        def render(model, width: model.cols.to_i)
          rows = [ "Choose project for new idea:" ]
          projects = nil
          if model.snapshot.nil?
            rows << Styles::HINT.render("Loading projects...")
          else
            projects = choices(model)
            if projects.empty?
              rows << Styles::FLASH.render("No healthy projects available")
            else
              cursor = model.new_idea_project_cursor.to_i.clamp(0, projects.size - 1)
              visible, first_idx = visible_projects(projects, cursor)
              visible.each_with_index do |project, idx|
                absolute_idx = first_idx + idx
                prefix = absolute_idx == cursor ? "> " : "  "
                line = "#{prefix}#{project.name}"
                rows << (absolute_idx == cursor ? Styles::CURSOR_HIGHLIGHT.render(line) : line)
              end
            end
          end
          # Always anchor the operator with at least an Esc-cancel hint —
          # loading + no-healthy-projects states used to render with no
          # exit affordance, making the mode look frozen.
          hint = projects && !projects.empty? ? "Enter choose  Esc cancel" : "Esc cancel"
          rows << Styles::HINT.render(hint)

          rows.map { |line| truncate(line, width) }.join("\n")
        end

        def choices(model)
          Array(model.snapshot&.projects).select { |project| project.error.nil? }
        end

        def visible_projects(projects, cursor)
          return [ projects, 0 ] if projects.size <= MAX_VISIBLE_PROJECTS

          start = [ cursor - MAX_VISIBLE_PROJECTS + 1, 0 ].max
          start = [ start, projects.size - MAX_VISIBLE_PROJECTS ].min
          [ projects[start, MAX_VISIBLE_PROJECTS], start ]
        end

        def truncate(line, width)
          usable = width.to_i
          return line if usable <= 0

          Views::Format.truncate(line, usable)
        end
      end
    end
  end
end
