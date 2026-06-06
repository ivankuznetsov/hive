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
      # scoped task list as a 6-column compact table inside a bordered
      # box. Replaces v1's project-grouped section format; project
      # context now lives in the left pane (Views::ProjectsPane).
      #
      # Columns: icon · id · display name · stage · status · age. Within each
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
          "archived"        => "✓ ",
          "ready_to_brainstorm" => "▶ ",
          "ready_to_plan"       => "▶ ",
          "ready_to_develop"    => "▶ ",
          "ready_to_open_pr"    => "▶ ",
          "ready_for_review"    => "▶ ",
          "ready_to_artifacts"  => "▶ ",
          "ready_to_finalize"   => "▶ ",
          "ready_to_archive"    => "▶ "
        }.freeze
        DEFAULT_ICON = "  ".freeze

        # Column widths (excluding 1-cell separators between columns).
        # The table consumes `inner_width` minus five separators (5 cells)
        # and fixed icon/id/stage/status/age columns. name is the elastic column —
        # it absorbs any extra width and is left-truncated when narrow.
        ICON_WIDTH = 2
        ID_WIDTH = 4
        STAGE_WIDTH = 12
        STATUS_WIDTH = 18
        AGE_WIDTH = 4
        SEPARATORS = 5 # spaces between the 6 columns

        module_function

        def render(model, width:, height: nil)
          inner_width = [ width - 2, 1 ].max
          body = build_body(model, inner_width, height: height)
          border_for(model).width(inner_width).render(body)
        end

        # Exposed for test-time identity assertion.
        def border_for(model)
          model.pane_focus == :right ? Styles::PANE_FOCUSED_BORDER : Styles::PANE_DIM_BORDER
        end

        # ---- Body sections ----

        def build_body(model, inner_width, height: nil)
          lines = []
          lines << Styles::HEADER.render(truncate(title_for(model), inner_width))
          lines << ""
          inner_height = height ? [ height.to_i - 2, 1 ].max : nil

          if model.snapshot.nil?
            lines << Styles::HINT.render(NO_SNAPSHOT_PLACEHOLDER)
            return fit_lines(lines, inner_height).join("\n")
          end

          visible = visible_snapshot(model)
          if visible.nil? || visible.projects.all? { |p| p.rows.empty? }
            lines << Styles::HINT.render(EMPTY_PLACEHOLDER)
            return fit_lines(lines, inner_height).join("\n")
          end

          layout = compute_layout(inner_width)
          # Walk the visible snapshot per-project so the per-row index we
          # check against `model.cursor[1]` matches the cursor's own
          # row-within-project semantics. A previous flat-rows iteration
          # mis-highlighted rows at scope=0 when registries had >1
          # project, because cursor[1] resets to 0 on next-project jump
          # while a flat iterator keeps incrementing.
          row_lines = []
          visible.projects.each_with_index do |project, project_idx|
            project.rows.each_with_index do |row, row_idx|
              row_lines << {
                coord: [ project_idx, row_idx ],
                text: render_row(row, project_idx, row_idx, model, layout)
              }
            end
          end

          lines = visible_task_lines(lines, row_lines, model.cursor, inner_height)
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

          snap.visible_projection(scope: model.scope, filter: model.filter)
        end

        # Below `inner_width = ICON+ID+STAGE+STATUS+AGE+SEPARATORS+name_min`
        # (~48 cells) the 5-column layout overflows. Drop columns in
        # priority order — first stage (mostly redundant with status),
        # then status — to keep the line within `inner_width` even on
        # very narrow terminals. The dropped columns silently shrink to
        # zero width; row-line builder pads with the remaining widths.
        def compute_layout(inner_width)
          name_min = 8
          fixed_full = ICON_WIDTH + ID_WIDTH + STAGE_WIDTH + STATUS_WIDTH + AGE_WIDTH + SEPARATORS
          if inner_width >= fixed_full + name_min
            { name: inner_width - fixed_full, stage: STAGE_WIDTH, status: STATUS_WIDTH }
          elsif inner_width >= ICON_WIDTH + ID_WIDTH + STATUS_WIDTH + AGE_WIDTH + 4 + name_min
            # Drop the stage column; separators reduce from 4 to 3.
            { name: inner_width - (ICON_WIDTH + ID_WIDTH + STATUS_WIDTH + AGE_WIDTH + 4), stage: 0, status: STATUS_WIDTH }
          elsif inner_width >= ICON_WIDTH + ID_WIDTH + AGE_WIDTH + 3 + name_min
            # Drop both stage and status.
            { name: inner_width - (ICON_WIDTH + ID_WIDTH + AGE_WIDTH + 3), stage: 0, status: 0 }
          else
            # Floor at name_min; row will overflow visually but won't crash.
            { name: name_min, stage: 0, status: 0 }
          end
        end

        def render_row(row, project_idx, row_idx, model, layout)
          highlighted = highlight?(model, project_idx, row_idx)
          icon = Format.ljust_cells(ICONS.fetch(row.action_key.to_s, DEFAULT_ICON), ICON_WIDTH)
          id = Format.rjust_cells(row.id ? row.id.to_s : "—", ID_WIDTH)
          name = Format.ljust_cells(display_name(row), layout[:name])
          age = Format.rjust_cells(Format.age(row.age_seconds), AGE_WIDTH)
          parts = [ icon, id, name ]
          parts << Format.ljust_cells(row.stage.to_s, layout[:stage]) if layout[:stage].positive?
          parts << Format.ljust_cells(status_label(row), layout[:status]) if layout[:status].positive?
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

        def display_name(row)
          value = row.display_name.to_s.strip
          value.empty? ? row.slug.to_s : value
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

          # max_passes-hit REVIEW_STALE has no `reason` attr but does
          # carry `pass=N`. Surface the pass number so the operator
          # sees WHY this row is stale (cap was reached) without
          # opening the file. Retryable shapes (`wall_clock`,
          # incomplete-triage) already returned above via the reason
          # branch; this branch is reached only for the max_passes-hit
          # shape that Enter now routes to OpenReviewStaleFile. Marker
          # comparison is lowercase because `Hive::Markers.current`
          # downcases the name to a symbol (`:review_stale`) and the
          # status payload stringifies that to "review_stale".
          pass = Hive::Tui::Text.sanitize(attrs["pass"])
          if row.marker.to_s == "review_stale" && !pass.empty?
            return "stale pass=#{pass}"
          end

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

        def visible_task_lines(header, row_lines, cursor, inner_height)
          return header + row_lines.map { |row| row[:text] } if inner_height.nil?
          return fit_lines(header, inner_height) if inner_height <= header.size

          capacity = inner_height - header.size
          selected_index = row_lines.index { |row| row[:coord] == cursor } || 0
          start = viewport_start(
            total: row_lines.size,
            capacity: capacity,
            selected_index: selected_index
          )
          fit_lines(header + row_lines.slice(start, capacity).to_a.map { |row| row[:text] }, inner_height)
        end

        def fit_lines(lines, height)
          return lines if height.nil?

          lines.first(height) + Array.new([ height - lines.size, 0 ].max, "")
        end

        def viewport_start(total:, capacity:, selected_index:)
          return 0 if total <= capacity

          selected = selected_index.clamp(0, total - 1)
          selected < capacity ? 0 : [ selected - capacity + 1, total - capacity ].min
        end
      end
    end
  end
end
