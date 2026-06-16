require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/tasks_pane"

# Hive::Tui::Views::TasksPane is the right pane of the v2 two-pane
# layout. These tests pin layout/text content via assert_includes and
# verify the focus-driven border distinction by border_for(model)
# identity (lipgloss strips ANSI in non-tty test environments).
class HiveTuiViewsTasksPaneTest < Minitest::Test
  include HiveTestHelper

  def make_task(slug:, stage: "2-brainstorm", action: "ready_to_plan",
                action_label: "Ready to plan", age: 120,
                marker: "complete", attrs: {},
                id: 42, display_name: nil,
                pr_url: nil,
                mtime: "2026-05-01T00:00:00Z",
                folder_mtime: "2026-05-01T00:00:00Z",
                depends_on: nil, blocked_by: nil, dependency_stage: nil,
                blocked: false,
                suggested: "hive plan #{slug} --from 2-brainstorm")
    {
      "slug" => slug,
      "id" => id,
      "display_name" => display_name,
      "depends_on" => depends_on,
      "blocked_by" => blocked_by,
      "dependency_stage" => dependency_stage,
      "blocked" => blocked,
      "stage" => stage,
      "folder" => "/tmp/#{slug}",
      "state_file" => "/tmp/#{slug}/brainstorm.md",
      "pr_url" => pr_url,
      "marker" => marker,
      "attrs" => attrs,
      "mtime" => mtime,
      "folder_mtime" => folder_mtime,
      "age_seconds" => age,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => action_label,
      "suggested_command" => suggested
    }
  end

  def make_snapshot(projects)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01T00:00:00Z",
      "projects" => projects
    )
  end

  def make_model(snapshot:, scope: 0, pane_focus: :right, cursor: [ 0, 0 ], filter: nil)
    Hive::Tui::Model.initial.with(snapshot: snapshot, scope: scope,
                                  pane_focus: pane_focus, cursor: cursor,
                                  filter: filter)
  end

  # Run the block with `$stdout.tty?` reporting true so the OSC 8 path in
  # Hyperlink/pr_cell is exercised. Swaps in a tty-reporting StringIO and
  # restores the original $stdout afterward.
  def with_tty_stdout
    original = $stdout
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    $stdout = io
    yield
  ensure
    $stdout = original
  end

  # ---- Title / scope ----

  def test_title_says_all_projects_when_scope_zero
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap, scope: 0), width: 80)
    assert_includes out, "Tasks · ★ All projects"
  end

  def test_title_says_project_name_when_scope_n
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001") ] },
      { "name" => "myapp", "tasks" => [ make_task(slug: "xyz-002") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap, scope: 2), width: 80)
    assert_includes out, "Tasks · myapp"
  end

  def test_render_omits_old_clean_archived_rows_but_keeps_visible_rows
    old = (Time.now - (5 * 86_400)).utc.iso8601
    recent = (Time.now - 86_400).utc.iso8601
    snap = make_snapshot([
                           { "name" => "hive", "tasks" => [
                             make_task(
                               slug: "old-archived",
                               stage: "9-done",
                               action: "archived",
                               action_label: "Archived",
                               marker: "complete",
                               mtime: old,
                               folder_mtime: old
                             ),
                             make_task(
                               slug: "recent-archived",
                               stage: "9-done",
                               action: "archived",
                               action_label: "Archived",
                               marker: "complete",
                               mtime: recent,
                               folder_mtime: recent
                             ),
                             make_task(slug: "active-task", stage: "4-execute", marker: "execute_complete")
                           ] }
                         ])

    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)

    refute_includes out, "old-archived"
    assert_includes out, "recent-archived"
    assert_includes out, "active-task"
  end

  # ---- Column rendering ----

  def test_renders_pr_column_after_id
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "abc-001", id: 7, display_name: "Readable Task", stage: "3-plan",
                  action_label: "Needs your input", age: 90,
                  pr_url: "https://github.com/example/repo/pull/561")
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "   7",             "id column must render"
    assert_match(/\s7\s+#561\s+Readable Task/, out,
                 "PR number must render between id and display name")
    assert_includes out, "Readable Task",    "display name column must render"
    refute_includes out, "abc-001",          "slug must not render when a display name is present"
    assert_includes out, "3-plan",           "stage column must render"
    assert_includes out, "Needs your input", "status column must render"
    assert_includes out, "1m",               "age column must render (90s → 1m)"
  end

  def test_renders_dash_pr_column_without_url
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "abc-001", id: 7, display_name: "Readable Task")
      ] }
    ])

    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)

    assert_match(/\s7\s+—\s+Readable Task/, out,
                 "rows without a PR must keep the fixed PR column with a dash")
  end

  # Exercises the TTY/OSC 8 `pr_cell` path directly: the TUI render
  # pipeline routes rows through lipgloss, which rewrites ANSI under a tty,
  # so the link contract is pinned on pr_cell itself. Assert the BEHAVIOR
  # (the two rjust spaces stay outside the link, the link wraps the #561
  # token) by reconstructing the expected link through the same osc8
  # builder, so a legitimate framing change (e.g. an added `id=`) doesn't
  # break the test as long as padding stays outside and the token inside.
  def test_pr_cell_wraps_token_and_keeps_padding_outside_link_under_tty
    url = "https://github.com/example/repo/pull/561"
    row = Struct.new(:pr_url).new(url)

    out = with_tty_stdout { Hive::Tui::Views::TasksPane.pr_cell(row, 6) }

    link = Hive::Tui::Views::Hyperlink.osc8("#561", url, enabled: true)
    assert_equal "  #{link}", out,
                 "two rjust spaces stay outside the OSC 8 link; the link wraps the #561 token"
  end

  # Over-width PR pin (plan accepts the >99999 width cap): rjust_cells
  # truncates "#100000" to the 6-cell column and the OSC 8 link must wrap
  # the *displayed* (truncated) token instead of being silently dropped —
  # the bug the pre-fix `cell.sub(/#token\z/)` produced once truncation
  # changed the suffix. Behavior is pinned via the osc8 builder so the
  # assertion survives an OSC 8 framing change.
  def test_pr_cell_wraps_displayed_truncated_token_for_over_width_pr_under_tty
    url = "https://github.com/example/repo/pull/100000"
    row = Struct.new(:pr_url).new(url)

    out = with_tty_stdout { Hive::Tui::Views::TasksPane.pr_cell(row, 6) }

    link = Hive::Tui::Views::Hyperlink.osc8("#1000…", url, enabled: true)
    assert_equal link, out,
                 "over-width PR must still emit the link, wrapping the truncated #1000… token"
  end

  # Symmetric negative of the tty pin (and of the status-text path's
  # refute_match(/\e\]8;;/) guard): a populated pr_url rendered through
  # pr_cell in a NON-tty must emit zero OSC 8 bytes, so the link is gated on
  # `$stdout.tty?` and never leaks escape sequences into piped/captured
  # output. The default test $stdout is non-tty, so pr_cell takes the
  # disabled branch here without any stubbing.
  def test_pr_cell_emits_no_osc8_in_non_tty
    url = "https://github.com/example/repo/pull/561"
    row = Struct.new(:pr_url).new(url)

    out = Hive::Tui::Views::TasksPane.pr_cell(row, 6)

    refute_match(/\e\]8;;/, out, "non-tty pr_cell must not emit OSC 8 bytes")
    assert_includes out, "#561", "the plain PR token must still render in non-tty"
  end

  def test_name_column_falls_back_to_slug_when_display_name_missing
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001", display_name: nil) ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "abc-001"
  end

  def test_blocked_row_status_shows_dependency
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "dependent-task", depends_on: "base-task",
                  blocked_by: "base-task", dependency_stage: "7-artifacts",
                  blocked: true)
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)

    # The dependency block is APPENDED to the action-state label, not a
    # replacement — so both appear. The fixed-width status column truncates
    # the tail, so assert the leading, truncation-stable portion here; the
    # exact composition is pinned by the direct status_label tests below.
    assert_includes out, "Ready to plan",
                    "a blocked row must keep its action-state label, not drop it for the block"
    assert_includes out, "blocked by",
                    "a blocked row must still surface the dependency block"
  end

  def test_status_label_appends_dependency_to_action_state
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "dependent-task", depends_on: "base-task",
                  blocked_by: "base-task", dependency_stage: "7-artifacts",
                  blocked: true)
      ] }
    ])
    row = snap.projects.first.rows.first

    assert_equal "Ready to plan ⏸ blocked by base-task (7-artifacts)",
                 Hive::Tui::Views::TasksPane.status_label(row),
                 "a blocked row must append the dependency block to its action-state label"
  end

  # CLAUDE.md test-rule 10: an at-gate dependent (blocked:false, prereq past
  # the gate) still carries depends_on/blocked_by but must NOT render the
  # "⏸ blocked by" indicator — status_label keys off `blocked`, not field
  # presence. Only an absence check catches a regression that keyed the badge
  # off depends_on/blocked_by presence and labelled a dispatchable task held.
  def test_status_label_omits_dependency_block_for_unblocked_dependent
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "unblocked-dependent", depends_on: "base-task",
                  blocked_by: "base-task", dependency_stage: "8-finalize",
                  blocked: false)
      ] }
    ])
    row = snap.projects.first.rows.first

    assert_equal "Ready to plan",
                 Hive::Tui::Views::TasksPane.status_label(row),
                 "an unblocked dependent must show only its action-state label"
    refute_includes Hive::Tui::Views::TasksPane.status_label(row), "blocked by",
                    "an unblocked dependent must NOT render the dependency block"
  end

  def test_render_omits_dependency_block_for_unblocked_dependent
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "unblocked-dependent", depends_on: "base-task",
                  blocked_by: "base-task", dependency_stage: "8-finalize",
                  blocked: false)
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)

    refute_includes out, "blocked by",
                    "a dispatchable (unblocked) dependent must not render the held indicator"
  end

  # A task can be blocked AND in an error/recover_review state (e.g. a human
  # manually `hive run`s a frozen dependent). Text mode appends the
  # dependency block to the error label via compact.join; the TUI must do the
  # same instead of dropping the error context for only the block.
  def test_status_label_blocked_error_row_keeps_both_error_and_dependency
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "blocked-and-errored",
          stage: "4-execute",
          action: "error",
          action_label: "Error",
          marker: "error",
          attrs: { "reason" => "exit_code", "exit_code" => "1" },
          depends_on: "base-task",
          blocked_by: "base-task",
          dependency_stage: "7-artifacts",
          blocked: true,
          suggested: nil
        )
      ] }
    ])
    row = snap.projects.first.rows.first

    assert_equal "ERROR exit_code=1 ⏸ blocked by base-task (7-artifacts)",
                 Hive::Tui::Views::TasksPane.status_label(row),
                 "a blocked error row must surface BOTH its error state and the dependency block"
  end

  def test_recover_review_status_shows_marker_reason
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "recover-me",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_error",
          attrs: { "phase" => "triage", "reason" => "triage_failed", "pass" => "2" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "triage_failed",
                    "review recovery rows must show the exact marker reason, not generic status text"
    refute_includes out, "Needs recovery"
  end

  def test_recover_review_status_falls_back_to_marker_when_reason_missing
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "recover-me",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_stale",
          attrs: {},
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "review_stale",
                    "review recovery rows must fall back to the marker name when no reason attr is present"
    refute_includes out, "Needs recovery"
  end

  def test_recover_review_status_surfaces_pass_for_max_passes_hit_stale
    # max_passes-hit REVIEW_STALE markers carry `pass=N` but no
    # `reason` attr. Operator needs to see the pass count to
    # understand WHY this row is stuck (cap was reached) without
    # opening the file. Mirrors the existing `wall_clock` /
    # `triage_failed` inline-diagnostic pattern.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "stale-me",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_stale",
          attrs: { "pass" => "4" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "stale pass=4",
                    "max_passes-hit REVIEW_STALE rows must surface the pass number inline"
    refute_includes out, "Needs recovery"
  end

  def test_recover_review_status_reason_wins_over_pass
    # Regression: when both `reason` and `pass` are present (the
    # retryable wall_clock / triage_failed shapes), `reason` wins.
    # The pass-attr branch must never override the existing reason
    # rendering, or `Enter` routing diverges from status display.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "wall-clocked",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_stale",
          attrs: { "reason" => "wall_clock", "pass" => "2" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "wall_clock",
                    "reason attr must take precedence over pass attr"
    refute_includes out, "stale pass=2"
  end

  def test_recover_review_status_strips_control_chars_in_pass_attr
    # Defensive: a marker file whose `pass=` attr was corrupted (or
    # injected) with ANSI escapes or control bytes must not corrupt
    # lipgloss column alignment or hijack the cursor. Sanitize
    # before rendering — mirrors the existing sanitize behavior on
    # `reason` attrs (see test_recover_review_status_strips_control_chars_and_ansi_escapes).
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "ansi-pass",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_stale",
          attrs: { "pass" => "4\e[31mansi\e[0m\nNL" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    refute_match(/\e\[/, out, "ANSI escape bytes must be stripped from pass attr")
    refute_match(/\nNL/, out, "literal newlines must be stripped from pass attr")
    assert_includes out, "stale pass=4",
                    "sanitized pass value must still render the prefix correctly"
  end

  def test_recover_review_status_falls_back_when_pass_attr_missing
    # Edge: legacy/malformed marker with REVIEW_STALE name but no
    # pass attribute falls back to the existing marker-name display.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "legacy-stale",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_stale",
          attrs: { "other_attr" => "x" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "review_stale",
                    "missing pass attr must fall back to the existing marker-name rendering"
    refute_includes out, "stale pass="
  end

  def test_recover_review_status_falls_back_to_action_label_when_marker_blank
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "recover-me",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "",
          attrs: {},
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "Needs recovery",
                    "review recovery rows must fall back to action_label when both reason and marker are blank"
  end

  def test_status_label_non_error_non_recover_review_ignores_reason_attr
    # Status enrichment is opt-in per action_key — only `recover_review`
    # and `error` rows surface marker attrs. Other action keys (here
    # `agent_running`) must keep their plain action_label even if
    # snapshot attrs would parse as something operator-readable.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "running-task",
          stage: "3-plan",
          action: "agent_running",
          action_label: "Agent running",
          marker: "agent_working",
          attrs: { "reason" => "should_not_appear" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "Agent running",
                    "non-enriched rows must keep their action_label as status"
    refute_includes out, "should_not_appear",
                     "non-enriched rows must not surface attrs[reason] in the status column"
  end

  # `error` rows surface the failure context in the status column so
  # the operator can read WHY a task failed without leaving the grid.
  # Before this enrichment the column rendered a flat "Error" with no
  # diagnostic, and the only way to see the exit code was to open the
  # log tail.
  def test_error_status_shows_exit_code_when_present
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "broken-task",
          stage: "3-plan",
          action: "error",
          action_label: "Error",
          marker: "error",
          attrs: { "reason" => "exit_code", "exit_code" => "1" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "ERROR exit_code=1",
                    "error rows must surface the exit_code in the status column for diagnostic visibility"
  end

  def test_error_status_falls_back_to_reason_when_exit_code_missing
    # `panic` keeps the status string under the fixed status column width so
    # the assertion compares against unrenderered text. Longer reasons
    # are truncated by the layout and a fragile substring assertion
    # would couple this test to STATUS_WIDTH; the renderer guarantee
    # we care about is the prefix shape, which short fixtures pin.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "broken-task",
          stage: "3-plan",
          action: "error",
          action_label: "Error",
          marker: "error",
          attrs: { "reason" => "panic" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "ERROR panic",
                    "error rows must fall back to the reason attr when no exit_code is set"
  end

  def test_error_status_falls_back_to_action_label_when_attrs_blank
    # Hand-written / legacy ERROR markers carry no attrs. The status
    # column should keep the plain "Error" label rather than render an
    # empty diagnostic suffix.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "legacy-error",
          stage: "3-plan",
          action: "error",
          action_label: "Error",
          marker: "error",
          attrs: {},
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "Error",
                    "error rows with no attrs must fall back to the bare action_label"
    refute_match(/ERROR\s+\|/, out,
                 "error rows must not render an empty 'ERROR ' prefix when no attrs are present")
  end

  def test_error_status_strips_control_chars_and_ansi_escapes
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "tainted-error",
          stage: "3-plan",
          action: "error",
          action_label: "Error",
          marker: "error",
          attrs: { "reason" => "bad\x1b[31mansi\x1b[0m\nNL" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    refute_match(/\e\[/, out, "ANSI CSI escapes must be stripped from the error status column")
    refute_match(/\nNL/, out, "embedded newlines must not bleed into the error status column")
  end

  def test_recover_review_status_strips_control_chars_and_ansi_escapes
    # Operator-supplied marker reasons can carry control bytes (CR/LF
    # from a stdout-tail snippet) or ANSI CSI escapes that would
    # corrupt lipgloss column alignment or hijack the cursor. The
    # status column must sanitise both before rendering.
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(
          slug: "tainted-task",
          stage: "6-review",
          action: "recover_review",
          action_label: "Needs recovery",
          marker: "review_error",
          attrs: { "reason" => "bad\x1b[31mansi\x1b[0m\nNL" },
          suggested: nil
        )
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    refute_match(/\e\[/, out, "ANSI CSI escapes must be stripped from the status column")
    refute_match(/\nNL/, out, "embedded newlines must not bleed into the status column")
  end

  def test_action_keys_pick_distinct_icons
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "running-task", action: "agent_running", action_label: "Agent running"),
        make_task(slug: "ready-task", action: "ready_to_plan", action_label: "Ready to plan"),
        make_task(slug: "error-task", action: "error", action_label: "Error")
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "🤖", "agent_running rows must show robot icon"
    assert_includes out, "▶",  "ready_* rows must show advance arrow"
    assert_includes out, "⚠",  "error rows must show warning icon"
  end

  def test_action_icon_cells_have_consistent_display_width
    icons = Hive::Tui::Views::TasksPane::ICONS.values + [ Hive::Tui::Views::TasksPane::DEFAULT_ICON ]
    cells = icons.map { |icon| Hive::Tui::Views::Format.ljust_cells(icon, Hive::Tui::Views::TasksPane::ICON_WIDTH) }
    assert cells.all? { |cell| Hive::Tui::Views::Format.display_width(cell) == Hive::Tui::Views::TasksPane::ICON_WIDTH },
           "every action icon cell must consume the fixed icon column width"
  end

  def test_wide_icon_does_not_shift_the_id_column
    # Contrast a wide double-cell emoji (🤖) against an action that
    # falls back to the narrow DEFAULT_ICON ("agent_working" is not in
    # ICONS): if either icon mis-pads to the fixed ICON_WIDTH the id
    # column shifts, so the offsets must stay equal across both. Both rows
    # carry a pr_url so the PR column is populated; the id offset is
    # located by each row's own id token rather than "first digit", which
    # the PR number would otherwise make ambiguous.
    pr_url = "https://github.com/example/repo/pull/561"
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "running-task", id: 7, action: "agent_running",
                  action_label: "Agent running", pr_url: pr_url),
        make_task(slug: "working-task", id: 8, action: "agent_working",
                  action_label: "Agent working", pr_url: pr_url)
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    ids = { "running-task" => "7", "working-task" => "8" }

    id_offsets = out.lines.grep(/running-task|working-task/).map do |row|
      slug = ids.keys.find { |candidate| row.include?(candidate) }
      prefix = row.split(ids.fetch(slug), 2).first
      Hive::Tui::Views::Format.display_width(prefix)
    end
    assert_equal [ 7, 7 ], id_offsets.sort,
                 "wide emoji icons must not shift fixed-width columns"
  end

  # ---- Sort order ----

  def test_rows_sorted_by_action_label_order
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "zzz-late",  action: "agent_running", action_label: "Agent running"),
        make_task(slug: "aaa-early", action: "ready_to_plan", action_label: "Ready to plan")
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    early_idx = out.index("aaa-early")
    late_idx = out.index("zzz-late")
    refute_nil early_idx
    refute_nil late_idx
    assert_operator early_idx, :<, late_idx,
                    "Ready-to-plan rows must precede Agent-running rows per ACTION_LABEL_ORDER"
  end

  # ---- Cursor highlight ----

  def test_cursor_highlight_only_applies_when_pane_focus_right
    # Verifies the focus-gating predicate directly. lipgloss strips ANSI
    # in non-tty so the rendered output cannot distinguish highlighted
    # rows; visual confirmation is via tty dogfood + e2e asciinema. The
    # boolean decision is what unit tests can pin.
    snap = make_snapshot([ { "name" => "p", "tasks" => [ make_task(slug: "t") ] } ])
    model_right = make_model(snapshot: snap, pane_focus: :right, cursor: [ 0, 0 ])
    model_left = make_model(snapshot: snap, pane_focus: :left, cursor: [ 0, 0 ])
    assert Hive::Tui::Views::TasksPane.highlight?(model_right, 0, 0),
           "right-focus cursor at [0,0] must highlight that row"
    refute Hive::Tui::Views::TasksPane.highlight?(model_left, 0, 0),
           "left-focus cursor at [0,0] must NOT highlight the right pane's row"
  end

  # Regression for the cursor-coord mismatch that flat-rows iteration
  # introduced. With cursor [1, 0] at scope=0 multi-project, the render
  # must highlight the FIRST row of the SECOND project, not the first
  # row of the first project (which the old `cursor[1] == flat_idx`
  # check did). Verified via the predicate.
  def test_highlight_aligns_with_project_idx_at_multi_project_scope
    snap = make_snapshot([
      { "name" => "p0", "tasks" => [ make_task(slug: "p0a"), make_task(slug: "p0b") ] },
      { "name" => "p1", "tasks" => [ make_task(slug: "p1c"), make_task(slug: "p1d") ] }
    ])
    model = make_model(snapshot: snap, scope: 0, pane_focus: :right, cursor: [ 1, 0 ])
    refute Hive::Tui::Views::TasksPane.highlight?(model, 0, 0),
           "cursor [1, 0] must NOT highlight project 0's first row " \
           "(regression: flat-rows iteration mismatched cursor coord)"
    assert Hive::Tui::Views::TasksPane.highlight?(model, 1, 0),
           "cursor [1, 0] must highlight project 1's first row"
    refute Hive::Tui::Views::TasksPane.highlight?(model, 1, 1),
           "cursor [1, 0] must NOT highlight project 1's second row"
  end

  def test_highlight_returns_false_when_cursor_is_nil
    model = Hive::Tui::Model.initial.with(snapshot: nil, pane_focus: :right, cursor: nil)
    refute Hive::Tui::Views::TasksPane.highlight?(model, 0, 0),
           "nil cursor must not highlight any row"
  end

  # ---- Border focus state ----

  def test_uses_focused_border_when_pane_focus_right
    snap = make_snapshot([])
    chosen = Hive::Tui::Views::TasksPane.border_for(make_model(snapshot: snap, pane_focus: :right))
    assert_same Hive::Tui::Styles::PANE_FOCUSED_BORDER, chosen
  end

  def test_uses_dim_border_when_pane_focus_left
    snap = make_snapshot([])
    chosen = Hive::Tui::Views::TasksPane.border_for(make_model(snapshot: snap, pane_focus: :left))
    assert_same Hive::Tui::Styles::PANE_DIM_BORDER, chosen
  end

  # ---- Edge / error cases ----

  def test_nil_snapshot_renders_loading_placeholder
    model = Hive::Tui::Model.initial.with(snapshot: nil, pane_focus: :right)
    out = Hive::Tui::Views::TasksPane.render(model, width: 80)
    assert_includes out, "loading", "nil snapshot must surface a loading hint, not crash"
  end

  def test_empty_visible_rows_renders_no_tasks_placeholder
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "real-task") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(
      make_model(snapshot: snap, filter: "definitely-not-matching"), width: 80
    )
    assert_includes out, "no tasks"
  end

  def test_long_slug_is_truncated_with_ellipsis
    long_slug = "this-is-a-very-long-slug-that-overflows-the-column"
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: long_slug) ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 80)
    refute_includes out, long_slug, "long slug must be truncated"
    assert_includes out, "…"
  end

  def test_narrow_width_does_not_crash
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "x") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 50)
    refute_nil out
    assert out.is_a?(String)
  end

  def test_snapshot_with_zero_projects_renders_no_tasks_placeholder
    snap = make_snapshot([])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 80)
    assert_includes out, "no tasks"
  end

  def test_height_clips_task_rows_but_keeps_cursor_visible
    tasks = 15.times.map { |idx| make_task(slug: "task-#{idx}", id: idx) }
    snap = make_snapshot([ { "name" => "hive", "tasks" => tasks } ])

    out = Hive::Tui::Views::TasksPane.render(
      make_model(snapshot: snap, cursor: [ 0, 14 ]), width: 100, height: 8
    )

    assert_equal 8, out.lines.count
    assert_includes out, "task-14", "task viewport must follow the selected cursor"
    refute_includes out, "task-0", "offscreen tasks must be clipped instead of overflowing the pane"
  end

  # ---- compute_layout adaptive column dropping ----
  # The full 7-column layout needs ~78 inner cells (icon=2, id=4,
  # pr=6, stage=12, status=36, age=4, separators=6, name_min=8). Below that, columns
  # drop in priority order: stage first (mostly redundant with status),
  # then status. These tests pin each branch so a future refactor of
  # the threshold values can't silently regress narrow-terminal
  # behavior — the BubbleModel composer tests at cols=60/69/70 only
  # exercise the full-5-column branch via single-pane fallback.

  def test_compute_layout_full_columns_at_wide_inner_width
    layout = Hive::Tui::Views::TasksPane.compute_layout(80)
    assert_operator layout[:name], :>=, 8
    assert_equal 6, layout[:pr]
    assert_equal 12, layout[:stage]
    assert_equal 36, layout[:status]
  end

  def test_compute_layout_drops_stage_at_medium_narrow_width
    layout = Hive::Tui::Views::TasksPane.compute_layout(70)
    assert_equal 6, layout[:pr], "PR column must never drop"
    assert_equal 0, layout[:stage], "medium-narrow widths must drop the stage column first"
    assert_operator layout[:status], :>, 0, "status survives when stage is dropped"
    assert_operator layout[:name], :>=, 8
  end

  def test_compute_layout_drops_stage_and_status_at_very_narrow_width
    # Even narrower — only icon, id, PR, name, age fit.
    layout = Hive::Tui::Views::TasksPane.compute_layout(35)
    assert_equal 6, layout[:pr], "PR column must survive the narrowest fitted branch"
    assert_equal 0, layout[:stage]
    assert_equal 0, layout[:status]
    assert_operator layout[:name], :>=, 8
  end

  def test_compute_layout_floors_slug_below_extreme_minimum
    # Below the very-narrow threshold: floor at name_min, dropping all
    # but icon/id/PR/name/age. Visual overflow is acknowledged — but no crash.
    layout = Hive::Tui::Views::TasksPane.compute_layout(10)
    assert_equal 8, layout[:name]
    assert_equal 6, layout[:pr]
    assert_equal 0, layout[:stage]
    assert_equal 0, layout[:status]
  end

  # ---- Format.age helper ----

  def test_format_age_handles_seconds
    assert_equal "30s", Hive::Tui::Views::Format.age(30)
  end

  def test_format_age_handles_minutes
    assert_equal "5m", Hive::Tui::Views::Format.age(300)
  end

  def test_format_age_handles_hours
    assert_equal "2h", Hive::Tui::Views::Format.age(7200)
  end

  def test_format_age_handles_days
    assert_equal "3d", Hive::Tui::Views::Format.age(259_200)
  end

  # ---- Format.truncate wide-glyph boundary ----

  def test_truncate_never_splits_a_double_width_glyph
    # "🤖🤖" is 4 cells. Truncating to 3 must keep the first whole emoji
    # plus the ellipsis (width 3) rather than emitting half of the
    # second glyph — the take_cells break guard prevents the overflow.
    result = Hive::Tui::Views::Format.truncate("🤖🤖", 3)

    assert_equal "🤖…", result, "truncation must land on a glyph boundary, not split a wide emoji"
    assert_operator Hive::Tui::Views::Format.display_width(result), :<=, 3,
                    "truncated output must never exceed the requested cell width"
  end

  def test_truncate_below_two_cells_drops_a_wide_glyph_without_ellipsis
    # max_width < 2 has no room for the ellipsis suffix, so it hard-cuts.
    # A single cell can't hold a 2-cell emoji, so the result is empty
    # rather than a half-glyph.
    result = Hive::Tui::Views::Format.truncate("🤖", 1)

    assert_equal "", result, "a 1-cell budget cannot hold a 2-cell glyph and must not split it"
  end
end
