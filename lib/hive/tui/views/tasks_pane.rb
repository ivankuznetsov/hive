require "lipgloss"
require "hive/agent_limit"
require "hive/commands/status"
require "hive/dependencies"
require "hive/pr"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/views/format"
require "hive/tui/views/hyperlink"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::TasksPane.render(model, width:) →
      # String`. Right pane of the v2 two-pane layout — renders the
      # scoped task list as a compact table inside a bordered
      # box. Replaces v1's project-grouped section format; project
      # context now lives in the left pane (Views::ProjectsPane).
      #
      # Columns: icon · id · PR · display name · stage · status · age. Within each
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
          "admission_error" => "⚠ ",
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
          "ready_to_archive"    => "▶ ",
          # Generic-workflow action keys (non-coding descriptors): a markerless
          # stage runs, a complete non-terminal stage advances. Without these
          # they fell through to DEFAULT_ICON and rendered iconless.
          "ready_to_run"        => "▶ ",
          "ready_to_advance"    => "▶ "
        }.freeze
        DEFAULT_ICON = "  ".freeze

        # Column widths (excluding 1-cell separators between columns).
        # The table consumes `inner_width` minus six separators (6 cells)
        # and fixed icon/id/pr/stage/status/age columns. name is the elastic column —
        # it absorbs any extra width and is left-truncated when narrow.
        ICON_WIDTH = 2
        ID_WIDTH = 4
        # Width of the PR column (`#NNN`), sourced from the shared
        # `Hive::Pr::NUMBER_WIDTH` so this pane and `hive status` text mode
        # (`Hive::Commands::Status::TEXT_PR_WIDTH`) can't drift on PR-column
        # width. PR numbers ≥ 100000 overflow/truncate this cell on purpose;
        # the plan accepts that cap.
        PR_WIDTH = Hive::Pr::NUMBER_WIDTH
        STAGE_WIDTH = 12
        STATUS_WIDTH = 36
        AGE_WIDTH = 4
        SEPARATORS = 6 # spaces between the 7 columns
        NAME_MIN_WIDTH = 13

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
          hidden_count = model.snapshot.hidden_archived_task_count(scope: model.scope)
          if hidden_count.positive?
            lines << Styles::HINT.render(
              truncate(hidden_archived_summary(hidden_count), inner_width)
            )
            lines << ""
          end
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

        def hidden_archived_summary(count)
          noun = count == 1 ? "task" : "tasks"
          "… and #{count} older archived #{noun} (hive archive to view)"
        end

        # Below `inner_width = ICON+ID+PR+STAGE+STATUS+AGE+SEPARATORS+NAME_MIN_WIDTH`
        # (~83 cells) the full layout overflows. Drop columns in
        # priority order — first stage (mostly redundant with status),
        # then status — to keep the line within `inner_width` even on
        # very narrow terminals. The PR column is fixed and never drops.
        # The dropped columns silently shrink to zero width; row-line
        # builder pads with the remaining widths.
        def compute_layout(inner_width)
          # Bind each branch's fixed (non-name) column cost to a local so the
          # guard threshold and the `name:` subtraction can never drift out
          # of sync — they read the same value by construction.
          fixed_full     = ICON_WIDTH + ID_WIDTH + PR_WIDTH + STAGE_WIDTH + STATUS_WIDTH + AGE_WIDTH + SEPARATORS
          fixed_no_stage = ICON_WIDTH + ID_WIDTH + PR_WIDTH + STATUS_WIDTH + AGE_WIDTH + (SEPARATORS - 1)
          fixed_minimal  = ICON_WIDTH + ID_WIDTH + PR_WIDTH + AGE_WIDTH + (SEPARATORS - 2)
          if inner_width >= fixed_full + NAME_MIN_WIDTH
            { name: inner_width - fixed_full, pr: PR_WIDTH, stage: STAGE_WIDTH, status: STATUS_WIDTH }
          elsif inner_width >= fixed_no_stage + NAME_MIN_WIDTH
            # Drop the stage column; separators reduce from 6 to 5.
            { name: inner_width - fixed_no_stage, pr: PR_WIDTH, stage: 0, status: STATUS_WIDTH }
          elsif inner_width >= fixed_minimal + NAME_MIN_WIDTH
            # Drop both stage and status.
            { name: inner_width - fixed_minimal, pr: PR_WIDTH, stage: 0, status: 0 }
          else
            # Floor at NAME_MIN_WIDTH; row will overflow visually but won't crash.
            { name: NAME_MIN_WIDTH, pr: PR_WIDTH, stage: 0, status: 0 }
          end
        end

        def render_row(row, project_idx, row_idx, model, layout)
          highlighted = highlight?(model, project_idx, row_idx)
          icon = Format.ljust_cells(ICONS.fetch(row.action_key.to_s, DEFAULT_ICON), ICON_WIDTH)
          id = Format.rjust_cells(row.id ? row.id.to_s : "—", ID_WIDTH)
          pr = pr_cell(row, layout[:pr])
          name = Format.ljust_cells(display_name(row), layout[:name])
          age = Format.rjust_cells(Format.age(row.age_seconds), AGE_WIDTH)
          parts = [ icon, id, pr, name ]
          parts << Format.ljust_cells(row.stage.to_s, layout[:stage]) if layout[:stage].positive?
          parts << Format.ljust_cells(status_label(row), layout[:status]) if layout[:status].positive?
          parts << age
          line = parts.join(" ")
          colored = Styles.for_action_key(row.action_key).render(line)
          highlighted ? Styles::CURSOR_HIGHLIGHT.render(colored) : colored
        end

        def pr_cell(row, width)
          token = Hive::Pr.number(row.pr_url) || "—"
          cell = Format.rjust_cells(token, width)
          return cell if token == "—"

          # rjust_cells truncates an over-width token ("#100000" → "#1000…"
          # at width 6; the plan accepts the >99999 cap). Wrap the
          # *displayed* token — the cell's trailing non-space run — rather
          # than the pre-truncation `token`, so the OSC 8 link survives
          # truncation instead of being silently dropped. Hyperlink.splice
          # wraps by offset (no String#sub backreference interpretation, no
          # per-row regex compile). Leading padding is rjust spaces only; the
          # displayed token (`#NNN`/`#NNN…`) never contains a space.
          pad_len = cell.length - cell.lstrip.length
          Hyperlink.splice(cell, pad_len, cell.length - pad_len, row.pr_url, enabled: $stdout.tty?)
        end

        def status_label(row)
          base = action_state_label(row)
          # Ownership is deliberately last. Fixed-width rendering truncates
          # the tail, preserving the action and dependency signals on narrow
          # layouts while still surfacing the owner when space permits.
          parts = [ base ]
          parts << dependency_status(row) if row.blocked && !row.admission_error
          parts << implementation_owner_token(row)
          parts.reject { |part| part.to_s.empty? }.join(" ")
        end

        def implementation_owner_token(row)
          execute = row.implementation_identity&.dig("stages", "execute")
          return nil unless execute && execute["provider"] && execute["model"]

          model = execute["model"].to_s
          model = "#{model[0, 11]}…" if model.length > 12
          "owner=#{execute['provider']}/#{model}"
        end

        # The action-state portion of the status column, independent of any
        # dependency block. Shared by status_label so the blocked and
        # unblocked paths compute the same base label.
        def action_state_label(row)
          return admission_error_status(row) if row.action_key.to_s == "admission_error"
          return review_recovery_status(row) if row.action_key.to_s == "recover_review"
          return error_status(row) if row.action_key.to_s == "error"

          row.action_label.to_s
        end

        def admission_error_status(row)
          error = row.admission_error || {}
          code = Hive::Tui::Text.sanitize(error["reason_code"])
          correction = Hive::Tui::Text.sanitize(error["safe_correction"])
          [ "ADMISSION #{code}", correction ].reject(&:empty?).join(": ")
        end

        def dependency_status(row)
          # Shared with Commands::Status#dependency_indicator so text mode
          # and the TUI can never diverge on the unresolved discriminator.
          Hive::Dependencies.blocked_label(
            depends_on: row.depends_on,
            blocked_by: row.blocked_by,
            dependency_stage: row.dependency_stage
          )
        end

        def display_name(row)
          value = row.display_name.to_s.strip
          value.empty? ? row.slug.to_s : value
        end

        # A detected provider quota wall short-circuits to the shared
        # `held_label` first; everything below is the exit_code/reason
        # fallback chain for non-held recovery markers.
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
          return Hive::AgentLimit.held_label(attrs) if Hive::AgentLimit.held?(row.marker, attrs)

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

        # A detected provider quota wall short-circuits to the shared
        # `held_label` first; the exit_code/reason fallback chain below
        # runs only for non-held error markers.
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
          return Hive::AgentLimit.held_label(attrs) if Hive::AgentLimit.held?(row.marker, attrs)

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
          start = Format.viewport_start(
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
      end
    end
  end
end
