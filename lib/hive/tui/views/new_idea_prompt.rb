require "lipgloss"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::NewIdeaPrompt.render(model) → String`.
      # Single bottom-strip line shown in `:new_idea` mode while the user
      # types a task title. Mirrors `Views::FilterPrompt`'s shape but
      # carries a project-scope label so the operator sees which project
      # the resulting `hive new <project> "<title>"` will land in before
      # pressing Enter.
      #
      # Project resolution for the label:
      # - `model.scope == 0` (★ All projects) → first registered project,
      #   prefixed with `★→` so the operator sees the implicit fallback.
      # - `model.scope == n` → the nth registered project.
      # - No registered projects → `(no projects)`; submission flashes an
      #   error in U6's BubbleModel handler instead of dispatching.
      module NewIdeaPrompt
        PROMPT_PREFIX = "New idea (project=".freeze

        module_function

        def render(model)
          buffer = model.new_idea_buffer.to_s
          cursor = Styles::CURSOR_HIGHLIGHT.render(" ")
          label = "#{PROMPT_PREFIX}#{project_label(model)}): "
          "#{Styles::HINT.render(label)}#{buffer}#{cursor}"
        end

        # Resolve which project an idea would land in. Pure read of the
        # snapshot; never raises (falls through to "(no projects)").
        def project_label(model)
          name = resolve_project_name(model)
          return "(no projects)" if name.nil?
          return "★→#{name}" if model.scope.zero?

          name
        end

        def resolve_project_name(model)
          snap = model.snapshot
          return nil if snap.nil? || snap.projects.empty?
          return snap.projects.first.name if model.scope.zero?
          return nil unless model.scope.between?(1, snap.projects.size)

          snap.projects[model.scope - 1].name
        end
      end
    end
  end
end
