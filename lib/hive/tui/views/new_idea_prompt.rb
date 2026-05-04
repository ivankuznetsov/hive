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

        # Multi-line wrap renderer. The buffer stays a single logical
        # line (Enter still submits — `hive new` takes a title, not
        # multi-paragraph content), but visually wraps across as many
        # rows as needed so the operator can see everything they typed.
        #
        # Row 1: `<label><first buffer chunk>`
        # Row 2..N: `<spaces aligned to label width><buffer chunk>`
        # Cursor block at the end of the last chunk.
        #
        # Caps the visible buffer at `MAX_VISIBLE_ROWS` rows; if the
        # buffer overflows that, the EARLIEST chunks scroll off (slide
        # like the single-line variant) so the cursor stays in view.
        # This keeps the prompt from growing unbounded and pushing the
        # task panes off-screen on a tall paste.
        MAX_VISIBLE_ROWS = 6

        def render(model, width: model.cols.to_i)
          buffer = model.new_idea_buffer.to_s
          label = "#{PROMPT_PREFIX}#{project_label(model)}): "
          # Available cells per row = width - 1 (cursor block) - 1
          # (right margin). Chunks are sized so `label-width padding +
          # chunk` always fits within `row_width`, keeping continuation
          # rows aligned to the same column as the first chunk.
          row_width = [ width - 2, 1 ].max
          chunk_capacity = [ row_width - label.length, 1 ].max
          chunks = chunk_buffer(buffer, chunk_capacity)
          visible = chunks.size > MAX_VISIBLE_ROWS ? chunks.last(MAX_VISIBLE_ROWS) : chunks
          render_rows(label, visible)
        end

        # Split `buffer` into chunks of `capacity` chars each. Always
        # returns at least one chunk (empty string) so the cursor has
        # somewhere to land.
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

        # Row 1: styled label + chunk
        # Row 2..N: spaces aligned to label width + chunk
        # Cursor block at the end of the last chunk only.
        def render_rows(label, chunks)
          cursor = Styles::CURSOR_HIGHLIGHT.render(" ")
          padding = " " * label.length
          rows = chunks.each_with_index.map do |chunk, idx|
            prefix = idx.zero? ? Styles::HINT.render(label) : padding
            if idx == chunks.size - 1
              "#{prefix}#{chunk}#{cursor}"
            else
              "#{prefix}#{chunk}"
            end
          end
          rows.join("\n")
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

          if model.scope.zero?
            # ★ All projects fallback: pick the first project that
            # is HEALTHY. Skipping projects with `error:` (missing
            # path / not initialised) prevents `hive new` from
            # exploding inside the dispatched subprocess against a
            # stale registration whose directory no longer exists.
            healthy = snap.projects.find { |p| p.error.nil? }
            return healthy&.name
          end
          return nil unless model.scope.between?(1, snap.projects.size)

          project = snap.projects[model.scope - 1]
          # An explicit scope onto an unhealthy project also returns
          # nil — submit_new_idea then flashes "no projects" rather
          # than dispatching against a doomed directory. The TUI's
          # left pane still shows the project (with its name) so the
          # operator can navigate elsewhere.
          return nil if project.error

          project.name
        end
      end
    end
  end
end
