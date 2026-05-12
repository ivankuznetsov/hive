require "lipgloss"
require "hive/commands/status"
require "hive/tui/styles"
require "hive/tui/text"
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
      # Columns: icon · slug · stage · status · age. Within each
      # project, rows are sorted by `Hive::Commands::Status::ACTION_LABEL_ORDER`
      # at Snapshot construction time, so "Ready to plan" appears above
      # "Agent running" within the same project. At ★ All projects
      # scope, projects are interleaved in `Hive::Config.registered_projects`
      # order — the sort is per-project, not global, so a "Ready to plan"
      # row in project P1 may visually appear after an "Agent running"
      # row in project P0. Operators relying on cross-project action
      # grouping should scope to a single project (1-9 or left-pane
      # selection) instead of staying on ★ All.
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

          visible = visible_snapshot(model)
          if visible.nil? || visible.projects.all? { |p| p.rows.empty? }
            lines << Styles::HINT.render(EMPTY_PLACEHOLDER)
            return lines.join("\n")
          end

          layout = compute_layout(inner_width)
          # Walk the visible snapshot per-project so the per-row index we
          # check against `model.cursor[1]` matches the cursor's own
          # row-within-project semantics. A previous flat-rows iteration
          # mis-highlighted rows at scope=0 when registries had >1
          # project, because cursor[1] resets to 0 on next-project jump
          # while a flat iterator keeps incrementing.
          visible.projects.each_with_index do |project, project_idx|
            project.rows.each_with_index do |row, row_idx|
              lines << render_row(row, project_idx, row_idx, model, layout)
            end
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

        # Visible-snapshot derivation — same shape v1 used. Returns the
        # full Snapshot (preserving project boundaries) so the renderer
        # can iterate per-project and the cursor's
        # [project_idx, row_idx_in_project] coordinate aligns with
        # rendering.
        def visible_snapshot(model)
          snap = model.snapshot
          return nil if snap.nil?

          snap.scope_to_project_index(model.scope).filter_by_slug(model.filter)
        end

        # Below `inner_width = ICON+STAGE+STATUS+AGE+SEPARATORS+slug_min`
        # (~48 cells) the 5-column layout overflows. Drop columns in
        # priority order — first stage (mostly redundant with status),
        # then status — to keep the line within `inner_width` even on
        # very narrow terminals. The dropped columns silently shrink to
        # zero width; row-line builder pads with the remaining widths.
        def compute_layout(inner_width)
          slug_min = 8
          fixed_full = ICON_WIDTH + STAGE_WIDTH + STATUS_WIDTH + AGE_WIDTH + SEPARATORS
          if inner_width >= fixed_full + slug_min
            { slug: inner_width - fixed_full, stage: STAGE_WIDTH, status: STATUS_WIDTH }
          elsif inner_width >= ICON_WIDTH + STATUS_WIDTH + AGE_WIDTH + 3 + slug_min
            # Drop the stage column; separators reduce from 4 to 3.
            { slug: inner_width - (ICON_WIDTH + STATUS_WIDTH + AGE_WIDTH + 3), stage: 0, status: STATUS_WIDTH }
          elsif inner_width >= ICON_WIDTH + AGE_WIDTH + 2 + slug_min
            # Drop both stage and status.
            { slug: inner_width - (ICON_WIDTH + AGE_WIDTH + 2), stage: 0, status: 0 }
          else
            # Floor at slug_min; row will overflow visually but won't crash.
            { slug: slug_min, stage: 0, status: 0 }
          end
        end

        def render_row(row, project_idx, row_idx, model, layout)
          highlighted = highlight?(model, project_idx, row_idx)
          icon = ICONS.fetch(row.action_key.to_s, DEFAULT_ICON)
          slug = truncate(row.slug.to_s, layout[:slug]).ljust(layout[:slug])
          age = Format.age(row.age_seconds).rjust(AGE_WIDTH)
          parts = [ "#{icon} #{slug}" ]
          parts << truncate(row.stage.to_s, layout[:stage]).ljust(layout[:stage]) if layout[:stage].positive?
          parts << truncate(status_label(row), layout[:status]).ljust(layout[:status]) if layout[:status].positive?
          parts << age
          line = parts.join(" ")
          colored = Styles.for_action_key(row.action_key).render(line)
          highlighted ? Styles::CURSOR_HIGHLIGHT.render(colored) : colored
        end

        def status_label(row)
          return review_recovery_status(row) if row.action_key.to_s == "recover_review"
          return error_status(row) if row.action_key.to_s == "error"

          row.action_label.to_s
        end

        # Operator-supplied marker reasons (stdout-tail snippets,
        # exception messages stored in REVIEW_ERROR's `reason` attr)
        # can carry control characters or ANSI CSI escapes that would
        # break lipgloss column alignment or hijack the cursor. Strip
        # them through `Hive::Tui::Text.sanitize` before returning.
        # The `marker` fallback is a constant from this codebase
        # (`REVIEW_ERROR` etc.) — sanitising too is cheap and keeps
        # the contract uniform regardless of which branch fires.
        def review_recovery_status(row)
          attrs = row.attrs || {}
          reason = Hive::Tui::Text.sanitize(attrs["reason"])
          return reason unless reason.empty?

          marker = Hive::Tui::Text.sanitize(row.marker)
          marker.empty? ? row.action_label.to_s : marker
        end

        # `error` action rows carry the failure context in `attrs`
        # (`reason=exit_code exit_code=1` for typical agent failures);
        # surfacing it in the status column tells the operator WHY a
        # task failed without leaving the grid. Falls back to the bare
        # "Error" label only when the marker has no exit_code or reason
        # — the legacy hand-written ERROR shape. Same sanitise
        # discipline as `review_recovery_status`: untrusted attr values
        # can carry CSI escapes that would hijack the cursor.
        def error_status(row)
          attrs = row.attrs || {}
          exit_code = Hive::Tui::Text.sanitize(attrs["exit_code"])
          reason = Hive::Tui::Text.sanitize(attrs["reason"])
          return "ERROR exit_code=#{exit_code}" unless exit_code.empty?
          return "ERROR #{reason}" unless reason.empty?

          row.action_label.to_s
        end

        # Local alias so call sites in this module keep their concise
        # `truncate(...)` shape; delegates to the shared Format helper
        # so ProjectsPane and TasksPane never drift on truncation rules.
        def truncate(label, max_width)
          Format.truncate(label, max_width)
        end

        # Predicate exposed for unit tests because lipgloss-ruby strips
        # ANSI in non-tty environments, so the rendered output of the
        # highlighted-row Style.render call is byte-identical to the
        # unhighlighted line. Tests verify the highlight DECISION here;
        # visual styling is verified by tty dogfood + e2e asciinema
        # frames per docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md.
        def highlight?(model, project_idx, row_idx)
          !model.cursor.nil? &&
            model.cursor == [ project_idx, row_idx ] &&
            model.pane_focus == :right
        end
      end
    end
  end
end
