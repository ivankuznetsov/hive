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

        # `width:` is the terminal width (model.cols). The label +
        # buffer + cursor must fit on a single line; longer buffers
        # slide the visible window so the cursor stays at the right
        # edge (real-shell behavior). Without this, the rendered line
        # overflows the terminal and disappears off the right side.
        def render(model, width: model.cols.to_i)
          buffer = model.new_idea_buffer.to_s
          label = "#{PROMPT_PREFIX}#{project_label(model)}): "
          # Available cells for the buffer = total - label - 1 (cursor)
          # - 1 (right margin so the cursor block doesn't sit at the
          # very last column where some terminals wrap).
          available = [ width - label.length - 2, 1 ].max
          visible_buffer = buffer.length <= available ? buffer : buffer[-available, available].to_s
          cursor = Styles::CURSOR_HIGHLIGHT.render(" ")
          "#{Styles::HINT.render(label)}#{visible_buffer}#{cursor}"
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
