require "lipgloss"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::ProjectsPane.render(model, width:) →
      # String`. Renders the left pane of the v2 two-pane layout — a
      # vertical list of registered projects with `★ All projects` pinned
      # to the top as a virtual entry. The selected entry (driven by
      # `model.scope`: 0 = ★, N = nth project) is reverse-video highlighted.
      #
      # Border style is decided by `model.pane_focus`: focused panes use
      # the cyan accent border; the inactive pane uses the dim grey one.
      # Lipgloss's rounded border falls back to ASCII corners on terminals
      # without Unicode box-drawing — no boot guard needed.
      #
      # The width: kwarg is the *outer* pane width (border included). Inner
      # content width = width - 2 (one cell of border on each side). Names
      # longer than the inner width are truncated with an ellipsis so the
      # box never overflows.
      #
      # Empty-snapshot path renders the ★ entry plus a placeholder line so
      # the pane still draws at boot before the first poll completes.
      module ProjectsPane
        ALL_PROJECTS_LABEL = "★ All projects".freeze
        TITLE = "Projects".freeze
        EMPTY_PLACEHOLDER = "(no projects;".freeze
        EMPTY_PLACEHOLDER_HINT = " run hive init)".freeze

        module_function

        def render(model, width:)
          inner_width = [ width - 2, 1 ].max
          rows = build_rows(model, inner_width)
          body = rows.join("\n")
          # Lipgloss chain methods return new Style instances; the frozen
          # base constants stay shared while each render gets its own
          # sized variant. No mutation, no FFI cost beyond the chain itself.
          border_for(model).width(inner_width).render(body)
        end

        # Exposed for test-time assertion — rendered border foreground
        # color isn't readable through lipgloss-ruby getters when stdout
        # is not a tty, so tests verify the chosen Style by identity here.
        def border_for(model)
          model.pane_focus == :left ? Styles::PANE_FOCUSED_BORDER : Styles::PANE_DIM_BORDER
        end

        # Visible row list: ★ All projects then each registered project,
        # in registry order. Empty snapshot still shows ★ plus a hint.
        def build_rows(model, inner_width)
          all_row = render_row(ALL_PROJECTS_LABEL, model.scope.zero?, inner_width)
          projects = (model.snapshot && model.snapshot.projects) || []
          if projects.empty?
            return [
              Styles::HEADER.render(truncate(TITLE, inner_width)),
              "",
              all_row,
              Styles::HINT.render(truncate(EMPTY_PLACEHOLDER, inner_width)),
              Styles::HINT.render(truncate(EMPTY_PLACEHOLDER_HINT, inner_width))
            ]
          end

          project_rows = projects.each_with_index.map do |project, idx|
            scope_index = idx + 1
            label = project_label(project)
            render_row(label, model.scope == scope_index, inner_width)
          end
          [
            Styles::HEADER.render(truncate(TITLE, inner_width)),
            "",
            all_row,
            *project_rows
          ]
        end

        def render_row(label, selected, inner_width)
          truncated = Format.truncate(label, inner_width)
          padded = truncated.ljust(inner_width)
          selected ? Styles::CURSOR_HIGHLIGHT.render(padded) : padded
        end

        # Project-row label decoration. Healthy projects render as
        # their name. Unhealthy projects (missing path, not initialised)
        # render with a `⚠` prefix and the short error label so the
        # operator sees at a glance which project to skip — without
        # this, broken projects are visually identical to healthy ones
        # and the user only finds out by trying to dispatch and seeing
        # `hive brainstorm` exit 70.
        def project_label(project)
          return project.name.to_s if project.error.nil?

          short = case project.error
          when "missing_project_path" then "missing"
          when "not_initialised" then "needs init"
          else project.error.to_s
          end
          "⚠ #{project.name} (#{short})"
        end

        # Predicate exposed for unit tests because lipgloss-ruby strips
        # ANSI in non-tty environments — so the rendered output of a
        # selected vs unselected row is byte-identical and tests can't
        # tell them apart from `assert_includes`. The boolean decision
        # IS observable here; visual styling is verified by tty
        # dogfood + e2e asciinema (same pattern as TasksPane#highlight?).
        # `scope_index` is 0 for the ★ All projects virtual row, then
        # 1..projects.size for each registered project.
        def selected?(model, scope_index)
          model.scope == scope_index
        end

        # Local alias so call sites in this module keep their concise
        # `truncate(...)` shape; delegates to the shared Format helper.
        def truncate(label, max_width)
          Format.truncate(label, max_width)
        end
      end
    end
  end
end
