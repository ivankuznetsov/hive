require "lipgloss"
require "hive/commands/status"
require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::TasksPane.render(model, width:) →
      # String`. Right pane of the v2 two-pane layout — renders the
      # scoped task list as a 5-column compact table inside a bordered
      # box. Replaces v1's project-grouped section format; project
      # context now lives in the left pane (Views::ProjectsPane).
      #
      # Columns: icon · slug · stage · status · age. Tasks are sorted by
      # `Hive::Commands::Status::ACTION_LABEL_ORDER` so "Ready to plan"
      # rows appear above "Agent running" rows etc. — the v1 grouping
      # value is preserved without v1's section-header overhead.
      #
      # Border style is decided by `model.pane_focus`: focused panes use
      # the cyan accent border; the inactive pane uses the dim grey one.
      #
      # The width: kwarg is the *outer* pane width (border included).
      # Inner content width = width - 2.
      module TasksPane
        TITLE_PREFIX = "Tasks · ".freeze
        ALL_PROJECTS_TITLE = "★ All projects".freeze
        EMPTY_PLACEHOLDER = "(no tasks)".freeze
        NO_SNAPSHOT_PLACEHOLDER = "(loading…)".freeze

        # Action_key → status icon. Single-codepoint Unicode where possible
        # so column alignment doesn't drift on terminals that render emoji
        # double-width. Fallback for unknown keys is the empty space.
        ICONS = {
          "agent_running"   => "🤖",
          "error"           => "⚠ ",
          "recover_execute" => "⚠ ",
          "recover_review"  => "⚠ ",
          "needs_input"     => "⏸ ",
          "review_findings" => "⏸ ",
          "archived"        => "✓ ",
          "ready_to_brainstorm" => "▶ ",
          "ready_to_plan"       => "▶ ",
          "ready_to_develop"    => "▶ ",
          "ready_for_review"    => "▶ ",
          "ready_for_pr"        => "▶ ",
          "ready_to_archive"    => "▶ "
        }.freeze
        DEFAULT_ICON = "  ".freeze

        # Column widths (excluding 1-cell separators between columns).
        # The table consumes `inner_width` minus four separators (4 cells)
        # and an icon column (2 cells). slug is the elastic column —
        # it absorbs any extra width and is left-truncated when narrow.
        ICON_WIDTH = 2
        STAGE_WIDTH = 12
        STATUS_WIDTH = 18
        AGE_WIDTH = 4
        SEPARATORS = 4 # spaces between the 5 columns

        module_function

        def render(model, width:)
          inner_width = [ width - 2, 1 ].max
          body = build_body(model, inner_width)
          border_for(model).width(inner_width).render(body)
        end

        # Exposed for test-time identity assertion.
        def border_for(model)
          model.pane_focus == :right ? Styles::PANE_FOCUSED_BORDER : Styles::PANE_DIM_BORDER
        end

        # ---- Body sections ----

        def build_body(model, inner_width)
          lines = []
          lines << Styles::HEADER.render(truncate(title_for(model), inner_width))
          lines << ""

          if model.snapshot.nil?
            lines << Styles::HINT.render(NO_SNAPSHOT_PLACEHOLDER)
            return lines.join("\n")
          end

          rows = visible_rows(model)
          if rows.empty?
            lines << Styles::HINT.render(EMPTY_PLACEHOLDER)
            return lines.join("\n")
          end

          slug_width = compute_slug_width(inner_width)
          rows.each_with_index do |row, idx|
            lines << render_row(row, idx, model, slug_width)
          end
          lines.join("\n")
        end

        def title_for(model)
          if model.scope.zero?
            "#{TITLE_PREFIX}#{ALL_PROJECTS_TITLE}"
          else
            project = model.snapshot && model.snapshot.projects[model.scope - 1]
            "#{TITLE_PREFIX}#{project ? project.name : '(unknown project)'}"
          end
        end

        # Visible rows derived from the same scope+filter logic v1 used.
        # The Snapshot operations are pure and return new instances.
        def visible_rows(model)
          snap = model.snapshot
          return [] if snap.nil?

          snap.scope_to_project_index(model.scope).filter_by_slug(model.filter).rows
        end

        def compute_slug_width(inner_width)
          fixed = ICON_WIDTH + STAGE_WIDTH + STATUS_WIDTH + AGE_WIDTH + SEPARATORS
          [ inner_width - fixed, 8 ].max
        end

        def render_row(row, idx, model, slug_width)
          highlighted = model.cursor && model.cursor[1] == idx && model.pane_focus == :right
          icon = ICONS.fetch(row.action_key.to_s, DEFAULT_ICON)
          slug = truncate(row.slug.to_s, slug_width).ljust(slug_width)
          stage = truncate(row.stage.to_s, STAGE_WIDTH).ljust(STAGE_WIDTH)
          status = truncate(row.action_label.to_s, STATUS_WIDTH).ljust(STATUS_WIDTH)
          age = Format.age(row.age_seconds).rjust(AGE_WIDTH)
          line = "#{icon} #{slug} #{stage} #{status} #{age}"
          colored = Styles.for_action_key(row.action_key).render(line)
          highlighted ? Styles::CURSOR_HIGHLIGHT.render(colored) : colored
        end

        def truncate(label, max_width)
          return "" if max_width <= 0
          return label if label.length <= max_width
          return label[0, max_width] if max_width < 2

          "#{label[0, max_width - 1]}…"
        end
      end
    end
  end
end
