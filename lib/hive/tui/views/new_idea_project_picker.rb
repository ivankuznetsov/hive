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
              rows << Styles::FLASH.render(empty_message(model.snapshot.new_idea_admission))
            else
              cursor = highlighted_cursor(model, projects)
              visible, first_idx = visible_projects(projects, cursor || 0)
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
          hint = if projects && !projects.empty?
            cursor.nil? ? "j/k select  Esc cancel" : "Enter choose  Esc cancel"
          else
            "Esc cancel"
          end
          rows << Styles::HINT.render(hint)

          rows.map { |line| truncate(line, width) }.join("\n")
        end

        def choices(model)
          model.snapshot&.new_idea_admission&.projects || []
        end

        def highlighted_cursor(model, projects)
          cursor = model.new_idea_project_cursor
          return nil unless cursor.is_a?(Integer) && cursor.between?(0, projects.size - 1)

          cursor
        end

        def empty_message(admission)
          case admission.state
          when :ambiguous
            names = admission.ambiguous_names.map(&:inspect).join(", ")
            "Duplicate project name #{names} — disambiguate registry or run `hive forget <name>`"
          when :unhealthy
            "No healthy projects available"
          when :no_projects
            "No projects registered — run `hive init <path>`"
          else
            "No selectable projects available"
          end
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
