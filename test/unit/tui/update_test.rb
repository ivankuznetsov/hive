require "test_helper"
require "hive/tui/model"
require "hive/tui/messages"
require "hive/tui/key_map"
require "hive/tui/update"

# Hive::Tui::Update is the MVU dispatcher: (Model, Message) → [Model, Cmd].
# These tests pin every Message → Update branch as a pure function call,
# without entering the Bubbletea runtime or rendering anything.
class HiveTuiUpdateTest < Minitest::Test
  include HiveTestHelper

  def model
    @model ||= Hive::Tui::Model.initial
  end

  def image_attached_message(label:, staging_path:, ext: "png")
    attachment = Hive::Tui::Model::Attachment.new(
      label: label,
      staging_path: staging_path,
      ext: ext
    )
    Hive::Tui::Messages::NewIdeaImageAttached.new(attachment: attachment)
  end

  def red_detail_row(marker: "review_error", attrs: { "phase" => "fix", "pass" => "1" },
                     action_key: "recover_review",
                     diagnostic: { "summary" => "REVIEW_ERROR", "detail" => "failed" })
    Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "6-review", slug: "red-task", folder: "/tmp/red-task",
      state_file: "/tmp/red-task/task.md", marker: marker, attrs: attrs, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: action_key, action_label: "Needs recovery", suggested_command: nil,
      next_action: nil, diagnostic: diagnostic
    )
  end

  def snapshot_with_rows(*rows)
    project = Hive::Tui::Snapshot::ProjectView.new(
      name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil, rows: rows.freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ project ])
  end

  # Compact Snapshot::Row factory for slug-follow tests. Absorbs the 14-field
  # `Hive::Tui::Snapshot::Row.new` signature so adding a new field there only
  # touches this one helper instead of every test that builds rows by hand.
  def build_row(project:, slug:, stage: "1-input", **overrides)
    defaults = {
      project_name: project, stage: stage, slug: slug, folder: nil,
      state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
      claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
      action_label: "ready", suggested_command: "hive brainstorm #{slug}",
      next_action: nil, diagnostic: nil
    }
    Hive::Tui::Snapshot::Row.new(**defaults.merge(overrides)).freeze
  end

  # Build a 2-project snapshot from a `{ alpha: [slug, ...], beta: [slug, ...] }`
  # spec. Used by the slug-follow tests to compose snapshot variants without
  # repeating ProjectView/Snapshot wiring.
  def slug_follow_snapshot(alpha:, beta:)
    pa = Hive::Tui::Snapshot::ProjectView.new(
      name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil,
      rows: alpha.map { |slug| build_row(project: "alpha", slug: slug) }.freeze
    ).freeze
    pb = Hive::Tui::Snapshot::ProjectView.new(
      name: "beta", path: "/b", hive_state_path: "/b/.h", error: nil,
      rows: beta.map { |slug| build_row(project: "beta", slug: slug) }.freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ pa, pb ])
  end

  # ---------- WindowSized ----------

  def test_window_sized_updates_dimensions
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::WindowSized.new(cols: 120, rows: 40))
    assert_equal 120, new_model.cols
    assert_equal 40, new_model.rows
    assert_nil cmd, "WindowSized has no side-effect Cmd"
  end

  def test_window_sized_reclamps_help_scroll_offset
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 1_000)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::WindowSized.new(cols: 80, rows: 200)
    )

    assert_equal :help, new_model.mode
    assert_equal Hive::Tui::Views::HelpOverlay.max_scroll_offset(new_model),
                 new_model.help_scroll_offset
  end

  # ---------- SnapshotArrived ----------

  def test_snapshot_arrived_replaces_snapshot_and_clears_last_error
    snap = snap_with_two_projects_three_rows_each
    starting = model.with(last_error: StandardError.new("stale"))
    new_model, cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap)
    )
    assert_same snap, new_model.snapshot
    assert_nil new_model.last_error, "successful poll must clear last_error so the stalled banner stops showing"
    assert_nil cmd
  end

  # A poll that drops rows the cursor was sitting on must reclamp
  # rather than leave model.cursor pointing at hidden rows; otherwise
  # downstream cursor handlers refuse to move from invalid coords and
  # the user is wedged with visible rows but no movable selection.
  def test_snapshot_arrived_reclamps_cursor_when_prior_coords_now_invalid
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      cursor: [ 1, 2 ] # last row of beta
    )
    # New snapshot: only project alpha exists with 1 row. The prior
    # cursor [1, 2] points at no-longer-existing project_idx 1.
    pa = Hive::Tui::Snapshot::ProjectView.new(
      name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil,
      rows: [ Hive::Tui::Snapshot::Row.new(
        project_name: "alpha", stage: "1-input", slug: "a1", folder: nil,
        state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
        action_label: "ready", suggested_command: "hive brainstorm a1", next_action: nil,
        diagnostic: nil
      ).freeze ].freeze
    ).freeze
    smaller_snap = Hive::Tui::Snapshot.new(generated_at: nil, projects: [ pa ])

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: smaller_snap)
    )
    assert_equal [ 0, 0 ], new_model.cursor,
      "cursor must reclamp to first visible row when prior coords no longer exist"
  end

  def test_snapshot_arrived_preserves_cursor_when_still_valid
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      cursor: [ 1, 1 ]
    )
    # A "benign" poll that re-emits the same snapshot — cursor must
    # not snap to the top, that would be UX-hostile.
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap_with_two_projects_three_rows_each)
    )
    assert_equal [ 1, 1 ], new_model.cursor,
      "still-valid cursor must be preserved across snapshot polls"
  end

  def test_snapshot_arrived_assigns_cursor_when_starting_from_nil
    starting = model.with(snapshot: nil, cursor: nil)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap_with_two_projects_three_rows_each)
    )
    assert_equal [ 0, 0 ], new_model.cursor,
      "first snapshot must seed cursor at first visible row instead of leaving it nil"
  end

  # The bug that motivated cursor_for_slug: with pure coord-preservation
  # reclamping, a poll that reorders rows within the cursor's project
  # leaves the cursor on whatever row now sits at the prior [project_idx,
  # row_idx]. The user keeps looking at the visually-highlighted row but
  # the next `s`/Enter dispatches against the row that *was* there — a
  # different task. The cursor must follow the SELECTED SLUG, not the
  # coords, so the highlighted row and the dispatched action always agree.
  def test_snapshot_arrived_cursor_follows_slug_when_rows_reorder_within_project
    starting = model.with(
      snapshot: slug_follow_snapshot(alpha: %w[a1 a2 a3], beta: %w[b1 b2 b3]),
      cursor: [ 1, 1 ] # beta/b2
    )
    # New snapshot — beta's rows are reordered so b2 now sits at row 0
    # (a peer above us advanced a stage, or sort order shifted).
    reordered = slug_follow_snapshot(alpha: %w[a1 a2 a3], beta: %w[b2 b1 b3])

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: reordered)
    )
    assert_equal [ 1, 0 ], new_model.cursor,
      "cursor must follow slug b2 to its new row when rows reorder, not stay on [1,1] (now b1)"
  end

  # When a row above the cursor disappears (peer advances, gets archived,
  # gets dropped by scope filter), the prior coords are still in-bounds
  # but point at the next task down. Coord-preserving reclamp would
  # silently shift the selection; slug-follow keeps it on the same task.
  def test_snapshot_arrived_cursor_follows_slug_when_row_above_disappears
    starting = model.with(
      snapshot: slug_follow_snapshot(alpha: %w[a1 a2 a3], beta: %w[b1 b2 b3]),
      cursor: [ 0, 1 ] # alpha/a2
    )
    # a1 disappears — alpha now holds [a2, a3]. Prior coords [0,1] are
    # still in bounds but now point at a3.
    snap = slug_follow_snapshot(alpha: %w[a2 a3], beta: %w[b1 b2 b3])

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap)
    )
    assert_equal [ 0, 0 ], new_model.cursor,
      "cursor must follow slug a2 to its new row 0, not stay on [0,1] (which is now a3)"
  end

  # When a task migrates between projects (the slug appears in a different
  # project in the new snapshot), `cursor_for_slug`'s prior-project lookup
  # misses and the global fallback loop must find the slug in its new home
  # so the cursor follows the task across the project boundary.
  def test_snapshot_arrived_cursor_follows_slug_across_projects
    starting = model.with(
      snapshot: slug_follow_snapshot(alpha: %w[a1 a2 a3], beta: %w[b1 b2 b3]),
      cursor: [ 0, 1 ] # alpha/a2
    )
    # a2 left alpha and now lives in beta as its second row. The prior
    # project lookup misses; the global scan must find it.
    snap = slug_follow_snapshot(alpha: %w[a1 a3], beta: %w[b1 a2 b2 b3])

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap)
    )
    assert_equal [ 1, 1 ], new_model.cursor,
      "cursor must follow slug a2 to its new project — global fallback loop must find it in beta"
  end

  # When the same slug appears in two projects, the cursor must stay
  # within the prior project. Slugs are not globally unique — two
  # `add-feature` tasks in different projects must not silently swap
  # the cursor between projects on a benign poll.
  def test_snapshot_arrived_cursor_prefers_prior_project_when_slug_is_not_unique
    snap = slug_follow_snapshot(alpha: %w[shared-slug], beta: %w[shared-slug])
    starting = model.with(snapshot: snap, cursor: [ 1, 0 ]) # cursor on beta's shared-slug

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap)
    )
    assert_equal [ 1, 0 ], new_model.cursor,
      "duplicate slug across projects must not steal the cursor — prior project_idx wins"
  end

  # When the selected slug is gone from the new snapshot entirely (the
  # task was archived, finalized, or filtered out by a scope change),
  # the cursor falls back to coord-preserving reclamp: keep the coords
  # if they're still in-bounds, otherwise snap to the first visible row.
  def test_snapshot_arrived_falls_back_to_reclamp_when_slug_disappears
    starting = model.with(
      snapshot: slug_follow_snapshot(alpha: %w[a1 a2 a3], beta: %w[b1 b2 b3]),
      cursor: [ 0, 1 ] # alpha/a2
    )
    # a2 is gone; alpha holds [a1, a3]. The slug cannot be followed, so
    # reclamp keeps [0,1] (still in bounds, now points at a3) — matching
    # the pre-existing reclamp behaviour for non-followable cursors.
    snap = slug_follow_snapshot(alpha: %w[a1 a3], beta: %w[b1 b2 b3])

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap)
    )
    assert_equal [ 0, 1 ], new_model.cursor,
      "lost slug must fall back to coord-preserving reclamp (here: still-in-bounds [0,1])"
  end

  def test_open_red_status_detail_enters_mode_with_agent_label
    # Pin the unified contract: opening the detail screen flips the
    # model into :red_status_detail and constructs a state with the
    # supplied row. The resolved agent_label flows in via the message
    # (BubbleModel#resolve_agent_label populates it before delegating
    # to Update.apply) so Update never reads the filesystem.
    row = red_detail_row(diagnostic: { "summary" => "REVIEW_ERROR" })
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::OpenRedStatusDetail.new(row: row, agent_label: "codex")
    )

    assert_nil cmd
    assert_equal :red_status_detail, new_model.mode
    assert_same row, new_model.red_status_detail_state.row
    assert_equal "codex", new_model.red_status_detail_state.agent_label
  end

  def test_open_red_status_detail_defaults_agent_label_when_missing
    # No resolver result (BubbleModel rescued a corrupt config) — the
    # state falls back to RedStatusDetailState::AGENT_FALLBACK so the
    # view never has to apply a render-time fallback.
    row = red_detail_row(diagnostic: nil)
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::OpenRedStatusDetail.new(row: row, agent_label: nil)
    )

    assert_equal Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK,
                 new_model.red_status_detail_state.agent_label
  end

  def test_open_implementation_identity_detail_enters_read_only_mode
    row = build_row(project: "alpha", slug: "owned")
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::OpenImplementationIdentityDetail.new(row: row)
    )

    assert_nil cmd
    assert_equal :implementation_identity_detail, new_model.mode
    assert_same row, new_model.implementation_identity_detail_state.row
  end

  def test_red_status_detail_scroll_down_reduces_offset
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: red_detail_row,
      log_lines: (1..50).map { |i| "line-#{i}" },
      log_scroll_offset: 5
    )
    starting = model.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :down, amount: 1)
    )

    assert_equal 4, new_model.red_status_detail_state.log_scroll_offset
  end

  def test_red_status_detail_scroll_up_increases_offset
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: red_detail_row,
      log_lines: (1..50).map { |i| "line-#{i}" },
      log_scroll_offset: 0
    )
    starting = model.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 10)
    )

    assert_equal 10, new_model.red_status_detail_state.log_scroll_offset
  end

  def test_red_status_detail_scroll_saturates_at_top
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: red_detail_row,
      log_lines: (1..50).map { |i| "line-#{i}" },
      log_scroll_offset: 0
    )
    starting = model.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 100)
    )

    assert_equal 46, new_model.red_status_detail_state.log_scroll_offset
  end

  # Boundary: :down from offset 0 must clamp to 0 (no negative). The
  # other paths exercise saturation at the top and the empty-log
  # no-op; this is the only test that pins the `[next, 0].max` floor.
  def test_red_status_detail_scroll_down_from_zero_clamps_to_zero
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: red_detail_row,
      log_lines: (1..50).map { |i| "line-#{i}" },
      log_scroll_offset: 0
    )
    starting = model.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :down, amount: 3)
    )

    assert_same starting, new_model,
                ":down from offset 0 must be a no-op (clamped at zero)"
  end

  def test_red_status_detail_scroll_empty_log_is_noop
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: red_detail_row,
      log_lines: [],
      log_scroll_offset: 0
    )
    starting = model.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 10)
    )

    assert_same starting, new_model
  end

  def test_snapshot_arrived_closes_red_detail_when_row_recovers
    row = red_detail_row
    starting = model.with(
      mode: :red_status_detail,
      red_status_detail_state: Hive::Tui::Model::RedStatusDetailState.new(row: row)
    )
    recovered = red_detail_row(marker: "review_complete", attrs: {}, action_key: "ready_to_artifacts")

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snapshot_with_rows(recovered))
    )

    assert_equal :grid, new_model.mode
    assert_nil new_model.red_status_detail_state
    assert_match(/recovered/, new_model.flash)
  end

  def test_snapshot_arrived_closes_red_detail_when_row_disappears
    row = red_detail_row
    starting = model.with(
      mode: :red_status_detail,
      red_status_detail_state: Hive::Tui::Model::RedStatusDetailState.new(row: row)
    )
    other = Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "6-review", slug: "other-task", folder: "/tmp/other-task",
      state_file: "/tmp/other-task/task.md", marker: "review_error", attrs: {}, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "recover_review", action_label: "Needs recovery", suggested_command: nil,
      next_action: nil, diagnostic: nil
    )

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snapshot_with_rows(other))
    )

    assert_equal :grid, new_model.mode
    assert_nil new_model.red_status_detail_state
    assert_match(/red-task no longer/, new_model.flash)
  end

  def test_snapshot_arrived_updates_red_detail_row_without_flash
    # The red-status detail screen now exposes only two actions; the
    # "marker changed — refresh (R)" flash relied on R-press which is
    # no longer in the keymap. A snapshot poll while the screen is
    # open quietly updates the cached row so the operator sees fresh
    # diagnosis the next time they re-open the screen.
    row = red_detail_row
    starting = model.with(
      mode: :red_status_detail,
      red_status_detail_state: Hive::Tui::Model::RedStatusDetailState.new(row: row)
    )
    changed = red_detail_row(attrs: { "phase" => "triage", "pass" => "2" })

    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::SnapshotArrived.new(snapshot: snapshot_with_rows(changed))
    )

    assert_equal :red_status_detail, new_model.mode
    assert_same changed, new_model.red_status_detail_state.row
    assert_nil new_model.flash
  end

  # ---------- PollFailed ----------


  def test_poll_failed_records_error_and_keeps_prior_snapshot
    prior_snapshot = Object.new
    starting = model.with(snapshot: prior_snapshot)
    err = StandardError.new("boom")
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::PollFailed.new(error: err)
    )
    assert_same err, new_model.last_error
    assert_same prior_snapshot, new_model.snapshot,
                "failed poll must keep prior snapshot so the user keeps seeing data"
  end

  # ---------- SubprocessExited ----------

  def test_subprocess_exited_zero_is_silent
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 0)
    )
    assert_nil new_model.flash, "exit 0 must NOT set a flash (success path is silent)"
    assert_nil new_model.flash_set_at
  end

  def test_subprocess_exited_nonzero_sets_flash_with_exit_code_and_log_pointer
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 4)
    )
    # Flash starts with the verb + exit code so the user sees the
    # core fact at a glance, then points at the stderr log file so
    # they can `tail` it for the full subprocess error output.
    assert_match(/\A`pr` exited 4 — tail /, new_model.flash)
    assert_includes new_model.flash, Hive::Tui::Subprocess.log_path
    refute_nil new_model.flash_set_at, "non-zero exit must stamp flash_set_at for TTL aging"
  end

  def test_subprocess_exited_nil_exit_code_is_silent
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: nil)
    )
    assert_nil new_model.flash
  end

  # ---------- InputEditorExited ----------

  def test_input_editor_exited_success_with_changes_sets_continue_hint
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::InputEditorExited.new(
        slug: "idea-260504-a1b2",
        exit_code: 0,
        changed: true
      )
    )

    assert_match(/edited idea-260504-a1b2/, new_model.flash)
    assert_match(/stage verb key/, new_model.flash)
    refute_nil new_model.flash_set_at
  end

  def test_input_editor_exited_success_without_changes_sets_noop_hint
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::InputEditorExited.new(
        slug: "idea-260504-a1b2",
        exit_code: 0,
        changed: false
      )
    )

    assert_match(/without changes/, new_model.flash)
    refute_nil new_model.flash_set_at
  end

  def test_input_editor_exited_nonzero_sets_exit_flash
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::InputEditorExited.new(
        slug: "idea-260504-a1b2",
        exit_code: 127,
        changed: false
      )
    )

    assert_match(/editor exited 127/, new_model.flash)
    refute_nil new_model.flash_set_at
  end

  # ---------- Tick (flash TTL aging) ----------

  def test_tick_clears_expired_flash
    starting = model.with(flash: "old", flash_set_at: Time.now - 10.0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::TICK)
    assert_nil new_model.flash, "expired flash must clear so the hint footer returns"
    assert_nil new_model.flash_set_at
  end

  def test_tick_preserves_active_flash
    fresh_set_at = Time.now - 1.0
    starting = model.with(flash: "fresh", flash_set_at: fresh_set_at)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::TICK)
    assert_equal "fresh", new_model.flash
    assert_equal fresh_set_at, new_model.flash_set_at
  end

  def test_tick_is_noop_when_no_flash
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TICK)
    assert_nil new_model.flash
    assert_nil cmd
  end

  def test_yield_tick_is_noop
    starting = model.with(flash: "fresh")
    new_model, cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::YIELD_TICK)
    assert_same starting, new_model
    assert_nil cmd
  end

  # ---------- TerminateRequested ----------

  def test_terminate_requested_returns_quit_command
    _new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TERMINATE_REQUESTED)
    # In tests Bubbletea isn't loaded; Update returns a sentinel. In
    # production (App.run_charm requires Bubbletea), the same call
    # returns Bubbletea.quit. Either way: not nil, signals exit.
    refute_nil cmd
  end

  def test_terminate_requested_does_not_mutate_model
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::TERMINATE_REQUESTED)
    assert_same model, new_model
  end

  def test_terminate_command_returns_sentinel_without_bubbletea
    bubbletea = Object.send(:remove_const, :Bubbletea) if Object.const_defined?(:Bubbletea)

    assert_equal :__terminate_sentinel__, Hive::Tui::Update.terminate_command
  ensure
    Object.const_set(:Bubbletea, bubbletea) if bubbletea
  end

  # ---------- FilterCharAppended ----------

  def test_filter_char_appended_extends_buffer
    starting = model.with(filter_buffer: "au")
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::FilterCharAppended.new(char: "t")
    )
    assert_equal "aut", new_model.filter_buffer
  end

  def test_filter_char_appended_works_on_empty_buffer
    new_model, _cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::FilterCharAppended.new(char: "a")
    )
    assert_equal "a", new_model.filter_buffer
  end

  # ---------- FilterCharDeleted ----------

  def test_filter_char_deleted_shrinks_buffer
    starting = model.with(filter_buffer: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CHAR_DELETED)
    assert_equal "aut", new_model.filter_buffer
  end

  def test_filter_char_deleted_on_empty_buffer_is_noop
    starting = model.with(filter_buffer: "")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CHAR_DELETED)
    assert_equal "", new_model.filter_buffer
  end

  # ---------- FilterCommitted ----------

  def test_filter_committed_promotes_buffer_to_active_filter_and_returns_to_grid
    starting = model.with(mode: :filter, filter_buffer: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_equal "auth", new_model.filter
    assert_equal "", new_model.filter_buffer
    assert_equal :grid, new_model.mode
  end

  # Committing a filter that hides the cursor's row must re-clamp the
  # cursor to the first visible match. Pre-fix, the prior cursor coords
  # could point at a row the new filter hid; downstream cursor handlers
  # treated that as "no current row" and refused to move, wedging the
  # user.
  def test_filter_committed_clamps_cursor_to_first_visible_match
    # Snapshot: alpha [a1,a2,a3], beta [b1,b2,b3]. Filter "b1" hides
    # all of alpha (empty rows after filter) and keeps only beta's b1.
    # Pre-fix, the prior cursor [0, 2] (alpha's last row) survived the
    # commit and pointed at a now-hidden row, wedging cursor handlers.
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      cursor: [ 0, 2 ],
      mode: :filter,
      filter_buffer: "b1"
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_equal :grid, new_model.mode
    assert_equal "b1", new_model.filter
    assert_equal [ 1, 0 ], new_model.cursor,
      "cursor must clamp to first visible row of the filtered snapshot " \
      "(beta's b1 at project_idx=1, row_idx=0); prior coords would point at hidden alpha"
  end

  def test_filter_committed_clears_cursor_when_filter_hides_everything
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      cursor: [ 0, 0 ],
      mode: :filter,
      filter_buffer: "no-such-row-anywhere"
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_equal :grid, new_model.mode
    assert_nil new_model.cursor,
      "filter that hides every row must leave cursor nil so views render an empty-state hint"
  end

  def test_filter_committed_with_empty_buffer_clears_active_filter
    starting = model.with(mode: :filter, filter: "old", filter_buffer: "")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_COMMITTED)
    assert_nil new_model.filter, "committing an empty buffer must clear any prior active filter"
  end

  # ---------- FilterCancelled ----------

  def test_filter_cancelled_returns_to_grid_and_clears_buffer
    starting = model.with(mode: :filter, filter_buffer: "wip", filter: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::FILTER_CANCELLED)
    assert_equal :grid, new_model.mode
    assert_equal "", new_model.filter_buffer
    # Esc preserves any previously-committed filter — the user clears
    # it via a separate keystroke in grid mode (the existing curses
    # behavior).
    assert_equal "auth", new_model.filter
  end

  # ---------- Token stats ----------

  def test_close_token_stats_returns_to_grid_and_clears_state
    state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :project,
      project_slug: "alpha"
    )
    starting = model.with(mode: :token_stats, token_stats_state: state)

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CLOSE_TOKEN_STATS)

    assert_equal :grid, new_model.mode
    assert_nil new_model.token_stats_state
  end

  def test_close_archive_pane_returns_to_grid
    starting = model.with(mode: :archive)

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CLOSE_ARCHIVE_PANE)

    assert_equal :grid, new_model.mode
  end

  def test_open_archive_pane_sets_archive_mode
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::OPEN_ARCHIVE_PANE)

    assert_equal :archive, new_model.mode
  end

  def test_close_archive_pane_from_other_mode_is_noop
    starting = model.with(mode: :grid)

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CLOSE_ARCHIVE_PANE)

    assert_same starting, new_model
  end

  def test_token_stats_scope_changed_drills_task_to_project_to_all
    state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :task,
      project_slug: "alpha",
      task_slug: "a1"
    )
    starting = model.with(mode: :token_stats, token_stats_state: state)

    project_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :out)
    )
    all_model, _cmd = Hive::Tui::Update.apply(
      project_model,
      Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :out)
    )

    assert_equal :project, project_model.token_stats_state.scope_level
    assert_equal "alpha", project_model.token_stats_state.project_slug
    assert_nil project_model.token_stats_state.task_slug
    assert_equal :all, all_model.token_stats_state.scope_level
  end

  def test_token_stats_scope_changed_drills_all_to_project_to_task
    starting = model.with(
      mode: :token_stats,
      snapshot: snap_with_two_projects_three_rows_each,
      token_stats_state: Hive::Tui::Model::TokenStatsState.new(scope_level: :all)
    )

    project_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :in)
    )
    task_model, _cmd = Hive::Tui::Update.apply(
      project_model,
      Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :in)
    )

    assert_equal :project, project_model.token_stats_state.scope_level
    assert_equal "alpha", project_model.token_stats_state.project_slug
    assert_equal :task, task_model.token_stats_state.scope_level
    assert_equal "alpha", task_model.token_stats_state.project_slug
    assert_equal "a1", task_model.token_stats_state.task_slug
  end

  def test_token_stats_selection_moves_between_projects_and_tasks
    project_state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :project,
      project_slug: "alpha"
    )
    project_model = model.with(
      mode: :token_stats,
      snapshot: snap_with_two_projects_three_rows_each,
      token_stats_state: project_state
    )
    moved_project, _cmd = Hive::Tui::Update.apply(
      project_model,
      Hive::Tui::Messages::TokenStatsSelectionMoved.new(direction: :next)
    )

    task_state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :task,
      project_slug: "alpha",
      task_slug: "a1"
    )
    task_model = project_model.with(token_stats_state: task_state)
    moved_task, _cmd = Hive::Tui::Update.apply(
      task_model,
      Hive::Tui::Messages::TokenStatsSelectionMoved.new(direction: :previous)
    )

    assert_equal "beta", moved_project.token_stats_state.project_slug
    assert_equal "a3", moved_task.token_stats_state.task_slug
  end

  # ---------- KeyPressed (stub) ----------

  def test_key_pressed_is_a_noop_in_u4_skeleton
    # KeyPressed handling lands in U5 once KeyMap returns Messages.
    # The U4 skeleton must not raise on KeyPressed — it returns the
    # model unchanged with no Cmd.
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::KeyPressed.new(key: "q")
    )
    assert_same model, new_model
    assert_nil cmd
  end

  # ---------- Unknown messages ----------

  def test_unknown_message_class_is_ignored
    # Future-compat: framework messages we don't dispatch on yet
    # (FocusMessage, BlurMessage, MouseMessage if mouse ever enables)
    # should pass through cleanly rather than raising.
    unknown = Class.new.new
    new_model, cmd = Hive::Tui::Update.apply(model, unknown)
    assert_same model, new_model
    assert_nil cmd
  end

  def test_open_in_agent_is_side_effect_owned_and_noops_in_update
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::OpenInAgent.new(row: Object.new)
    )

    assert_same model, new_model
    assert_nil cmd
  end

  def test_agent_steer_exited_is_side_effect_owned_and_noops_in_update
    new_model, cmd = Hive::Tui::Update.apply(
      model,
      Hive::Tui::Messages::AgentSteerExited.new(
        slug: "manual-task",
        folder: "/tmp/hive/manual-task",
        exit_code: 0,
        worktree: "/tmp/hive.worktrees/manual-task"
      )
    )

    assert_same model, new_model
    assert_nil cmd
  end

  # ---------- Pure-function discipline ----------

  def test_apply_does_not_mutate_input_model
    starting = model.with(snapshot: Object.new)
    Hive::Tui::Update.apply(starting, Hive::Tui::Messages::WindowSized.new(cols: 99, rows: 33))
    assert_equal 80, starting.cols, "Update must not mutate the input model"
    assert_equal 24, starting.rows
  end

  # ---------- Keystroke-derived handlers (U10) ----------

  require "hive/tui/snapshot"

  def snap_with_two_projects_three_rows_each
    rows_a = (1..3).map do |i|
      Hive::Tui::Snapshot::Row.new(
        project_name: "alpha", stage: "1-input", slug: "a#{i}", folder: nil,
        state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
        action_label: "ready to brainstorm", suggested_command: "hive brainstorm a#{i}",
        next_action: nil, diagnostic: nil
      ).freeze
    end
    rows_b = (1..3).map do |i|
      Hive::Tui::Snapshot::Row.new(
        project_name: "beta", stage: "1-input", slug: "b#{i}", folder: nil,
        state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
        action_label: "ready to brainstorm", suggested_command: "hive brainstorm b#{i}",
        next_action: nil, diagnostic: nil
      ).freeze
    end
    pa = Hive::Tui::Snapshot::ProjectView.new(name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil, rows: rows_a.freeze).freeze
    pb = Hive::Tui::Snapshot::ProjectView.new(name: "beta",  path: "/b", hive_state_path: "/b/.h", error: nil, rows: rows_b.freeze).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ pa, pb ])
  end

  def test_flash_message_sets_flash_with_timestamp
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::Flash.new(text: "hello"))
    assert_equal "hello", new_model.flash
    refute_nil new_model.flash_set_at
  end

  def test_cursor_down_moves_within_project
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 0, 1 ], new_model.cursor
  end

  def test_cursor_down_uses_archive_filtered_rows
    hidden = build_row(
      project: "alpha",
      slug: "old-archived",
      stage: "9-done",
      marker: "complete",
      action_key: "archived",
      action_label: "Archived",
      folder_mtime: (Time.now - (5 * 86_400)).utc.iso8601
    )
    visible = build_row(project: "alpha", slug: "visible-row")
    snap = snapshot_with_rows(hidden, visible)
    starting = model.with(snapshot: snap, cursor: [ 0, 0 ])

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)

    assert_equal [ 0, 0 ], new_model.cursor,
                 "after filtering the hidden archived row, the only visible row is already selected"
  end

  def test_cursor_down_jumps_to_next_project_at_last_row
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 1, 0 ], new_model.cursor
  end

  def test_cursor_down_clamps_at_end_of_last_project
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 1, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 1, 2 ], new_model.cursor, "must clamp rather than wrap"
  end

  def test_cursor_up_jumps_to_previous_project_at_first_row
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 1, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 2 ], new_model.cursor
  end

  # ---- v2 pane focus + left-pane cursor routing ----

  def test_pane_focus_toggled_flips_right_to_left
    starting = model.with(pane_focus: :right)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::PANE_FOCUS_TOGGLED)
    assert_equal :left, new_model.pane_focus
  end

  def test_pane_focus_toggled_flips_left_to_right
    starting = model.with(pane_focus: :left)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::PANE_FOCUS_TOGGLED)
    assert_equal :right, new_model.pane_focus
  end

  def test_pane_focus_changed_sets_explicit_target_left
    new_model, _cmd = Hive::Tui::Update.apply(
      model.with(pane_focus: :right),
      Hive::Tui::Messages::PaneFocusChanged.new(target: :left)
    )
    assert_equal :left, new_model.pane_focus
  end

  def test_pane_focus_changed_sets_explicit_target_right
    new_model, _cmd = Hive::Tui::Update.apply(
      model.with(pane_focus: :left),
      Hive::Tui::Messages::PaneFocusChanged.new(target: :right)
    )
    assert_equal :right, new_model.pane_focus
  end

  def test_pane_focus_changed_with_invalid_target_is_no_op
    # Defensive guard so a future bug in the keystroke pipeline can't
    # leave pane_focus in an unrecognised state.
    starting = model.with(pane_focus: :left)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::PaneFocusChanged.new(target: :sideways)
    )
    assert_equal :left, new_model.pane_focus
  end

  # Regression: below TWO_PANE_MIN_COLS the projects pane is suppressed.
  # If the user could still move focus to :left, j/k would mutate
  # hidden project scope and the visible task table would lose its
  # highlight. Single-pane mode pins focus to :right.
  def test_pane_focus_toggled_pinned_to_right_below_min_cols
    starting = model.with(pane_focus: :left, cols: 60)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::PANE_FOCUS_TOGGLED)
    assert_equal :right, new_model.pane_focus,
                 "Tab in single-pane mode must pin focus to :right (the only visible pane)"
  end

  # ---- v2 g/G jump nav ----

  def test_cursor_jump_top_under_left_focus_resets_scope_to_zero
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 2
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_JUMP_TOP)
    assert_equal 0, new_model.scope, "g on left pane must jump to ★ All projects (scope=0)"
  end

  def test_cursor_jump_bottom_under_left_focus_jumps_to_last_project
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 0
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_JUMP_BOTTOM)
    assert_equal 2, new_model.scope, "G on left pane must jump to the last registered project"
  end

  def test_cursor_jump_top_under_right_focus_lands_on_first_visible_row
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :right, cursor: [ 1, 2 ]
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_JUMP_TOP)
    assert_equal [ 0, 0 ], new_model.cursor, "g on right pane must land on the first row of the first project"
  end

  def test_cursor_jump_bottom_under_right_focus_lands_on_last_row_of_last_project
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :right, cursor: [ 0, 0 ]
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_JUMP_BOTTOM)
    assert_equal [ 1, 2 ], new_model.cursor, "G on right pane must land on the last row of the last project"
  end

  def test_cursor_jump_top_with_nil_snapshot_is_no_op
    starting = model.with(snapshot: nil, pane_focus: :right, cursor: [ 0, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_JUMP_TOP)
    assert_equal starting.cursor, new_model.cursor
  end

  def test_pane_focus_changed_left_rejected_below_min_cols
    starting = model.with(pane_focus: :right, cols: 60)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::PaneFocusChanged.new(target: :left)
    )
    assert_equal :right, new_model.pane_focus,
                 "h in single-pane mode must NOT focus a hidden pane"
  end

  def test_cursor_down_under_left_focus_increments_scope
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 0
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal 1, new_model.scope, "j on left pane should advance scope from 0 → 1"
  end

  def test_cursor_down_under_left_focus_clamps_at_max_scope
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 2 # already at the last project
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal 2, new_model.scope, "must not advance past projects.size"
  end

  def test_cursor_up_under_left_focus_decrements_scope
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 2
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal 1, new_model.scope
  end

  def test_cursor_up_under_left_focus_clamps_at_zero
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :left, scope: 0
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal 0, new_model.scope, "must not decrement below 0 (★ All projects)"
  end

  # ---- v2 new-idea mode lifecycle ----

  def test_open_new_idea_prompt_sets_mode_and_clears_buffer
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1", staging_path: "/tmp/image-1.png", ext: "png"
    )
    starting = model.with(
      mode: :grid,
      snapshot: snap_with_two_projects_three_rows_each,
      scope: 1,
      new_idea_project_name: "old-project",
      new_idea_project_cursor: 2,
      new_idea_buffer: "leftover-text",
      new_idea_cursor: 4,
      new_idea_attachments: [ attachment ],
      new_idea_staging_dir: "/tmp/hive-tui-composer",
      new_idea_staging_tmp_root: "/tmp"
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT)
    assert_equal :new_idea, new_model.mode
    assert_nil new_model.new_idea_project_name
    assert_equal 0, new_model.new_idea_project_cursor
    assert_equal "", new_model.new_idea_buffer
    assert_equal 0, new_model.new_idea_cursor
    assert_equal [], new_model.new_idea_attachments
    assert_nil new_model.new_idea_staging_dir
    assert_nil new_model.new_idea_staging_tmp_root
  end

  def test_open_new_idea_from_all_projects_opens_project_picker
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, scope: 0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT)
    assert_equal :new_idea_project, new_model.mode
    assert_nil new_model.new_idea_project_name
    assert_equal 0, new_model.new_idea_project_cursor
  end

  def test_open_new_idea_from_all_projects_before_snapshot_opens_project_picker
    starting = model.with(snapshot: nil, scope: 0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT)
    assert_equal :new_idea_project, new_model.mode
    assert_nil new_model.new_idea_project_name
    assert_equal 0, new_model.new_idea_project_cursor
  end

  def test_open_new_idea_from_explicit_scope_opens_title_prompt
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, scope: 2)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT)
    assert_equal :new_idea, new_model.mode
    assert_nil new_model.new_idea_project_name
  end

  def test_new_idea_project_picker_selects_project_without_changing_scope
    starting = model.with(
      mode: :new_idea_project,
      snapshot: snap_with_two_projects_three_rows_each,
      scope: 0,
      new_idea_project_cursor: 1
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED)
    assert_equal :new_idea, new_model.mode
    assert_equal "beta", new_model.new_idea_project_name
    assert_equal 0, new_model.scope
  end

  def test_new_idea_project_picker_enter_without_snapshot_flashes_waiting
    starting = model.with(mode: :new_idea_project, snapshot: nil, scope: 0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED)
    assert_equal :new_idea_project, new_model.mode,
                 "Enter on a nil-snapshot picker must stay in picker (not advance silently)"
    assert_nil new_model.new_idea_project_name
    assert_match(/waiting for snapshot/i, new_model.flash.to_s,
                 "Enter on a loading picker must acknowledge the keystroke via flash so the mode does not appear frozen")
  end

  def test_new_idea_project_picker_enter_when_all_unhealthy_flashes_no_healthy
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-19",
      "projects" => [
        { "name" => "broken-a", "error" => "missing_project_path", "tasks" => [] },
        { "name" => "broken-b", "error" => "not_initialised", "tasks" => [] }
      ]
    )
    starting = model.with(mode: :new_idea_project, snapshot: snap, scope: 0)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED)
    assert_equal :new_idea_project, new_model.mode,
                 "Enter against an all-unhealthy snapshot must stay in picker (not advance to composer with nil project)"
    assert_nil new_model.new_idea_project_name
    assert_match(/no healthy projects/i, new_model.flash.to_s,
                 "must acknowledge the keystroke and explain why selection is impossible")
  end

  def test_new_idea_project_picker_skips_unhealthy_projects
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-17",
      "projects" => [
        { "name" => "broken", "error" => "missing_project_path", "tasks" => [] },
        { "name" => "hive", "tasks" => [] },
        { "name" => "writero", "tasks" => [] }
      ]
    )
    starting = model.with(mode: :new_idea_project, snapshot: snap, new_idea_project_cursor: 0)
    down, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_DOWN)
    assert_equal 1, down.new_idea_project_cursor
    selected, _cmd = Hive::Tui::Update.apply(down, Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED)
    assert_equal "writero", selected.new_idea_project_name
  end

  def test_new_idea_project_picker_cursor_up_moves_with_choices
    starting = model.with(
      mode: :new_idea_project,
      snapshot: snap_with_two_projects_three_rows_each,
      new_idea_project_cursor: 1
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_UP)
    assert_equal 0, new_model.new_idea_project_cursor
  end

  def test_new_idea_project_picker_cursor_up_with_no_choices_is_noop
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-22",
      "projects" => [
        { "name" => "broken", "error" => "missing_project_path", "tasks" => [] }
      ]
    )
    starting = model.with(mode: :new_idea_project, snapshot: snap, new_idea_project_cursor: 3)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_UP)
    assert_same starting, new_model
  end

  def test_new_idea_text_inserted_in_empty_buffer_advances_cursor
    starting = model.with(mode: :new_idea, new_idea_buffer: "", new_idea_cursor: 0)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NewIdeaTextInserted.new(text: "rss")
    )
    assert_equal "rss", new_model.new_idea_buffer
    assert_equal 3, new_model.new_idea_cursor
  end

  def test_new_idea_text_inserted_in_middle_preserves_suffix
    starting = model.with(mode: :new_idea, new_idea_buffer: "fix bu", new_idea_cursor: 4)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NewIdeaTextInserted.new(text: "cache ")
    )
    assert_equal "fix cache bu", new_model.new_idea_buffer
    assert_equal 10, new_model.new_idea_cursor
  end

  def test_new_idea_cursor_left_and_right_clamp_at_boundaries
    starting = model.with(mode: :new_idea, new_idea_buffer: "rss", new_idea_cursor: 1)

    left_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CURSOR_LEFT)
    assert_equal 0, left_model.new_idea_cursor

    still_left, _cmd = Hive::Tui::Update.apply(left_model, Hive::Tui::Messages::NEW_IDEA_CURSOR_LEFT)
    assert_equal 0, still_left.new_idea_cursor

    right_model, _cmd = Hive::Tui::Update.apply(
      model.with(mode: :new_idea, new_idea_buffer: "rss", new_idea_cursor: 3),
      Hive::Tui::Messages::NEW_IDEA_CURSOR_RIGHT
    )
    assert_equal 3, right_model.new_idea_cursor
  end

  def test_new_idea_cursor_home_and_end_jump_to_buffer_edges
    starting = model.with(mode: :new_idea, new_idea_buffer: "rss feeds", new_idea_cursor: 3)

    home_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CURSOR_HOME)
    assert_equal 0, home_model.new_idea_cursor

    end_model, _cmd = Hive::Tui::Update.apply(home_model, Hive::Tui::Messages::NEW_IDEA_CURSOR_END)
    assert_equal "rss feeds".length, end_model.new_idea_cursor
  end

  def test_new_idea_char_deleted_shrinks_buffer
    starting = model.with(mode: :new_idea, new_idea_buffer: "rss feeds", new_idea_cursor: 9)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED)
    assert_equal "rss feed", new_model.new_idea_buffer
    assert_equal 8, new_model.new_idea_cursor
  end

  def test_new_idea_backspace_deletes_character_before_cursor
    starting = model.with(mode: :new_idea, new_idea_buffer: "fix bug", new_idea_cursor: 5)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED)
    assert_equal "fix ug", new_model.new_idea_buffer
    assert_equal 4, new_model.new_idea_cursor
  end

  def test_new_idea_char_deleted_on_empty_buffer_stays_empty
    starting = model.with(mode: :new_idea, new_idea_buffer: "")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED)
    assert_equal "", new_model.new_idea_buffer
    assert_equal 0, new_model.new_idea_cursor
    assert_equal :new_idea, new_model.mode, "delete-on-empty must not change mode"
  end

  def test_new_idea_delete_forward_removes_character_under_cursor
    starting = model.with(mode: :new_idea, new_idea_buffer: "fix bug", new_idea_cursor: 4)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED_FORWARD
    )
    assert_equal "fix ug", new_model.new_idea_buffer
    assert_equal 4, new_model.new_idea_cursor
  end

  def test_new_idea_delete_forward_at_tail_is_noop
    starting = model.with(mode: :new_idea, new_idea_buffer: "rss", new_idea_cursor: 3)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED_FORWARD
    )
    assert_equal "rss", new_model.new_idea_buffer
    assert_equal 3, new_model.new_idea_cursor
  end

  def test_new_idea_unicode_cursor_operations_do_not_split_characters
    starting = model.with(mode: :new_idea, new_idea_buffer: "åβc", new_idea_cursor: 2)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED)
    assert_equal "åc", new_model.new_idea_buffer
    assert_equal 1, new_model.new_idea_cursor
  end

  def test_new_idea_paste_text_normalizes_line_breaks_and_tabs
    starting = model.with(mode: :new_idea, new_idea_buffer: "fix ", new_idea_cursor: 4)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NewIdeaTextInserted.new(text: "bug\n\treport\rnow")
    )
    assert_equal "fix bug report now", new_model.new_idea_buffer
    assert_equal "fix bug report now".length, new_model.new_idea_cursor
  end

  def test_new_idea_image_attached_in_empty_buffer_inserts_placeholder
    starting = model.with(mode: :new_idea, new_idea_buffer: "", new_idea_cursor: 0)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      image_attached_message(
        label: "image1",
        staging_path: "/tmp/hive-tui-composer/image-1.png",
        ext: "png"
      )
    )

    assert_equal "[image1]", new_model.new_idea_buffer
    assert_equal 8, new_model.new_idea_cursor
    assert_equal 1, new_model.new_idea_attachments.size
    assert_equal "image1", new_model.new_idea_attachments.first.label
    assert_equal "/tmp/hive-tui-composer/image-1.png", new_model.new_idea_attachments.first.staging_path
    assert_equal "png", new_model.new_idea_attachments.first.ext
  end

  def test_new_idea_backspace_prunes_orphaned_image_attachment
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1", staging_path: "/tmp/image-1.png", ext: "png"
    )
    starting = model.with(
      mode: :new_idea,
      new_idea_buffer: "[image1]",
      new_idea_cursor: "[image1]".length,
      new_idea_attachments: [ attachment ]
    )

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED)

    assert_equal "[image1", new_model.new_idea_buffer
    assert_equal 7, new_model.new_idea_cursor
    assert_equal [], new_model.new_idea_attachments
  end

  def test_new_idea_image_attached_inserts_at_cursor
    starting = model.with(mode: :new_idea, new_idea_buffer: "see ", new_idea_cursor: 4)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      image_attached_message(
        label: "image1",
        staging_path: "/tmp/hive-tui-composer/image-1.png",
        ext: "png"
      )
    )

    assert_equal "see [image1]", new_model.new_idea_buffer
    assert_equal 12, new_model.new_idea_cursor
  end

  def test_new_idea_image_attached_keeps_order_for_consecutive_images
    first, _cmd = Hive::Tui::Update.apply(
      model.with(mode: :new_idea, new_idea_buffer: "", new_idea_cursor: 0),
      image_attached_message(
        label: "image1",
        staging_path: "/tmp/hive-tui-composer/image-1.png",
        ext: "png"
      )
    )
    second, _cmd = Hive::Tui::Update.apply(
      first,
      image_attached_message(
        label: "image2",
        staging_path: "/tmp/hive-tui-composer/image-2.png",
        ext: "png"
      )
    )

    assert_equal "[image1][image2]", second.new_idea_buffer
    assert_equal %w[image1 image2], second.new_idea_attachments.map(&:label)
  end

  # R6: cursor in the middle of the buffer — the suffix branch of
  # `prefix + placeholder + suffix` must keep typed text after the
  # paste point intact and advance the cursor past the placeholder.
  def test_new_idea_image_attached_inserts_mid_buffer
    starting = model.with(
      mode: :new_idea,
      new_idea_buffer: "before after",
      new_idea_cursor: 7
    )
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      image_attached_message(
        label: "image1",
        staging_path: "/tmp/hive-tui-composer/image-1.png",
        ext: "png"
      )
    )

    assert_equal "before [image1]after", new_model.new_idea_buffer
    assert_equal 7 + "[image1]".length, new_model.new_idea_cursor
  end

  # R5: three consecutive paste events must produce monotonic
  # `image1 / image2 / image3` labels AND three distinct staging
  # paths, regardless of how attachments.size moves.
  def test_new_idea_image_attached_three_consecutive_pastes_label_monotonically
    starting = model.with(mode: :new_idea, new_idea_buffer: "", new_idea_cursor: 0)
    final = %w[image1 image2 image3].each_with_index.reduce(starting) do |state, (label, idx)|
      next_model, _cmd = Hive::Tui::Update.apply(
        state,
        image_attached_message(
          label: label,
          staging_path: "/tmp/hive-tui-composer/image-#{idx + 1}.png",
          ext: "png"
        )
      )
      next_model
    end

    assert_equal %w[image1 image2 image3], final.new_idea_attachments.map(&:label)
    paths = final.new_idea_attachments.map(&:staging_path)
    assert_equal paths.uniq, paths, "three consecutive pastes must yield three distinct staging paths"
    assert_equal 3, final.new_idea_attachment_counter
  end

  # The Update-layer test for "at-cap insert is refused without a
  # partial token" used to live here. It was removed when the
  # buffer-overflow gate was consolidated into BubbleModel#stage_image
  # (the only caller path that produces a NewIdeaImageAttached
  # message) so two duplicate gates against
  # NEW_IDEA_BUFFER_MAX_CHARS could not drift. The behaviour is
  # covered at the BubbleModel layer in
  # test_new_idea_image_paste_at_buffer_cap_is_refused_without_orphan_file.

  # NewIdeaSubmitBlocked was removed in 2026-05-13: it was a dead
  # Data type that was defined and tested but never dispatched (rich-
  # submit failures set the flash directly via `model.with`). Test
  # kept as a placeholder for the contract that submit failures still
  # surface a flash without clobbering the buffer — see the
  # `submit_rich_new_idea` tests in bubble_model_test.rb for the live
  # path.

  def test_new_idea_over_limit_insert_partial_fits_and_flashes_truncation
    # 6 cells of remaining capacity, 10-char paste → fit 6, flash truncation.
    existing = "x" * (Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS - 6)
    starting = model.with(mode: :new_idea, new_idea_buffer: existing, new_idea_cursor: existing.length)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NewIdeaTextInserted.new(text: "abcdefghij")
    )
    assert_equal existing + "abcdef", new_model.new_idea_buffer
    assert_equal Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS, new_model.new_idea_buffer.length
    assert_equal Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS, new_model.new_idea_cursor
    assert_match(/truncated/i, new_model.flash.to_s)
    refute_nil new_model.flash_set_at
  end

  def test_new_idea_at_limit_insert_preserves_buffer_and_flashes_too_long
    # Buffer already at the cap → any further insert is rejected entirely.
    existing = "x" * Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS
    starting = model.with(mode: :new_idea, new_idea_buffer: existing, new_idea_cursor: existing.length)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::NewIdeaTextInserted.new(text: "yz")
    )
    assert_equal existing, new_model.new_idea_buffer
    assert_equal existing.length, new_model.new_idea_cursor
    # Match by intent rather than exact string so a UX copy edit
    # ("title at max length", localisation, etc.) does not break the
    # behavioural contract pin.
    assert_match(/too long|max/i, new_model.flash.to_s)
    refute_nil new_model.flash_set_at
  end

  def test_filter_text_inserted_appends_to_filter_buffer
    starting = model.with(mode: :filter, filter_buffer: "au")
    new_model, _cmd = Hive::Tui::Update.apply(
      starting, Hive::Tui::Messages::FilterTextInserted.new(text: "th")
    )
    assert_equal "auth", new_model.filter_buffer
    assert_equal :filter, new_model.mode
  end

  def test_new_idea_cancelled_returns_to_grid_and_clears_buffer
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1", staging_path: "/tmp/image-1.png", ext: "png"
    )
    starting = model.with(
      mode: :new_idea,
      new_idea_project_name: "hive",
      new_idea_project_cursor: 1,
      new_idea_buffer: "rss feeds",
      new_idea_cursor: 4,
      new_idea_attachments: [ attachment ],
      new_idea_staging_dir: "/tmp/hive-tui-composer",
      new_idea_staging_tmp_root: "/tmp"
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::NEW_IDEA_CANCELLED)
    assert_equal :grid, new_model.mode
    assert_nil new_model.new_idea_project_name
    assert_equal 0, new_model.new_idea_project_cursor
    assert_equal "", new_model.new_idea_buffer
    assert_equal 0, new_model.new_idea_cursor
    assert_equal [], new_model.new_idea_attachments
    assert_nil new_model.new_idea_staging_dir
    assert_nil new_model.new_idea_staging_tmp_root
  end

  def test_back_from_red_status_detail_closes_and_reclamps_cursor
    row = red_detail_row
    starting = model.with(
      mode: :red_status_detail,
      snapshot: snapshot_with_rows(row),
      cursor: [ 0, 9 ],
      red_status_detail_state: Hive::Tui::Model::RedStatusDetailState.new(row: row)
    )

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)

    assert_equal :grid, new_model.mode
    assert_nil new_model.red_status_detail_state
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_back_from_new_idea_project_cancels_composer_state
    starting = model.with(
      mode: :new_idea_project,
      new_idea_project_name: "alpha",
      new_idea_project_cursor: 1,
      new_idea_buffer: "draft",
      new_idea_cursor: 2
    )

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)

    assert_equal :grid, new_model.mode
    assert_nil new_model.new_idea_project_name
    assert_equal 0, new_model.new_idea_project_cursor
    assert_equal "", new_model.new_idea_buffer
    assert_equal 0, new_model.new_idea_cursor
  end

  def test_cursor_down_under_right_focus_preserves_v1_behaviour
    # Regression guard: v1 cursor row navigation must still work when
    # pane_focus is :right (the default and v1 implicit behaviour).
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :right, cursor: [ 0, 0 ]
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_DOWN)
    assert_equal [ 0, 1 ], new_model.cursor
  end

  def test_cursor_up_clamps_at_top
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 0 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_cursor_up_under_right_focus_decrements_row
    starting = model.with(
      snapshot: snap_with_two_projects_three_rows_each,
      pane_focus: :right,
      cursor: [ 0, 2 ]
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 1 ], new_model.cursor
  end

  def test_cursor_up_under_right_focus_skips_empty_projects
    row = Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "1-input", slug: "a1", folder: nil,
      state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: 0,
      claude_pid: nil, claude_pid_alive: nil, action_key: "ready_to_brainstorm",
      action_label: "ready", suggested_command: "hive brainstorm a1",
      next_action: nil, diagnostic: nil
    ).freeze
    alpha = Hive::Tui::Snapshot::ProjectView.new(name: "alpha", path: "/a", hive_state_path: "/a/.h", error: nil, rows: [ row ].freeze).freeze
    empty = Hive::Tui::Snapshot::ProjectView.new(name: "empty", path: "/e", hive_state_path: "/e/.h", error: nil, rows: [].freeze).freeze
    gamma = Hive::Tui::Snapshot::ProjectView.new(name: "gamma", path: "/g", hive_state_path: "/g/.h", error: nil, rows: [ row ].freeze).freeze
    snap = Hive::Tui::Snapshot.new(generated_at: nil, projects: [ alpha, empty, gamma ])
    starting = model.with(snapshot: snap, pane_focus: :right, cursor: [ 2, 0 ])

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::CURSOR_UP)
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_show_help_sets_mode_to_help
    new_model, _cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::SHOW_HELP)
    assert_equal :help, new_model.mode
  end

  def test_show_help_resets_help_scroll_offset
    starting = model.with(help_scroll_offset: 12)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::SHOW_HELP)

    assert_equal :help, new_model.mode
    assert_equal 0, new_model.help_scroll_offset
  end

  def test_help_scroll_down_increases_offset
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 0)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: 3)
    )

    assert_equal 3, new_model.help_scroll_offset
  end

  def test_help_scroll_up_decreases_offset
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 5)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :up, amount: 2)
    )

    assert_equal 3, new_model.help_scroll_offset
  end

  def test_help_scroll_down_clamps_to_bottom
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 0)
    max = Hive::Tui::Views::HelpOverlay.max_scroll_offset(starting)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: Hive::Tui::KeyMap::SCROLL_TO_EDGE)
    )

    assert_operator max, :>, 0
    assert_equal max, new_model.help_scroll_offset
  end

  def test_help_scroll_up_from_top_is_noop
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 0)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :up, amount: 1)
    )

    assert_same starting, new_model
  end

  def test_help_scroll_down_at_bottom_is_noop
    starting = model.with(mode: :help, cols: 80, rows: 14)
    max = Hive::Tui::Views::HelpOverlay.max_scroll_offset(starting)
    bottom = starting.with(help_scroll_offset: max)
    new_model, _cmd = Hive::Tui::Update.apply(
      bottom,
      Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: 1)
    )

    assert_same bottom, new_model
  end

  def test_help_scroll_ignores_non_help_mode
    starting = model.with(mode: :grid, help_scroll_offset: 5)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :down, amount: 1)
    )

    assert_same starting, new_model
  end

  def test_help_scroll_unknown_direction_keeps_offset
    starting = model.with(mode: :help, cols: 80, rows: 14, help_scroll_offset: 2)
    new_model, _cmd = Hive::Tui::Update.apply(
      starting,
      Hive::Tui::Messages::HelpScroll.new(direction: :sideways, amount: 5)
    )

    assert_same starting, new_model,
                "an unrecognized scroll direction must leave the help offset untouched"
  end

  def test_open_filter_prompt_pre_fills_buffer_with_active_filter
    starting = model.with(filter: "auth")
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::OPEN_FILTER_PROMPT)
    assert_equal :filter, new_model.mode
    assert_equal "auth", new_model.filter_buffer
  end

  def test_back_from_log_tail_clears_tail_state
    starting = model.with(mode: :log_tail, tail_state: Object.new)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)
    assert_equal :grid, new_model.mode
    assert_nil new_model.tail_state
  end

  def test_back_from_help_returns_to_grid
    starting = model.with(mode: :help)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)
    assert_equal :grid, new_model.mode
  end

  def test_back_from_idea_preview_clears_state_and_returns_to_grid
    state = Hive::Tui::Model::InfoPanelState.new(
      slug: "some-slug",
      stage: "2-brainstorm",
      created_at: nil,
      original_text: "original idea",
      folder_path: "/tmp/hive/some-slug",
      latest_log_path: nil,
      stage_extra: nil
    )
    starting = model.with(mode: :idea_preview, info_panel_state: state)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)

    assert_equal :grid, new_model.mode
    assert_nil new_model.info_panel_state
  end

  def test_back_from_implementation_identity_detail_clears_state
    row = build_row(project: "alpha", slug: "owned")
    state = Hive::Tui::Model::ImplementationIdentityDetailState.new(row: row)
    starting = model.with(
      mode: :implementation_identity_detail,
      implementation_identity_detail_state: state
    )

    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)

    assert_equal :grid, new_model.mode
    assert_nil new_model.implementation_identity_detail_state
  end

  def test_back_from_idea_preview_preserves_cursor_and_scope
    starting = model.with(
      mode: :idea_preview,
      info_panel_state: Hive::Tui::Model::InfoPanelState.new(
        slug: "some-slug",
        stage: "2-brainstorm",
        created_at: nil,
        original_text: "original idea",
        folder_path: "/tmp/hive/some-slug",
        latest_log_path: nil,
        stage_extra: nil
      ),
      cursor: [ 1, 2 ],
      scope: 2
    )
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::BACK)

    assert_equal [ 1, 2 ], new_model.cursor
    assert_equal 2, new_model.scope
  end

  def test_project_scope_sets_scope_and_resets_cursor
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, cursor: [ 0, 2 ])
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::ProjectScope.new(n: 2))
    assert_equal 2, new_model.scope
    assert_equal [ 0, 0 ], new_model.cursor
  end

  def test_project_scope_zero_clears_scope
    starting = model.with(snapshot: snap_with_two_projects_three_rows_each, scope: 1)
    new_model, _cmd = Hive::Tui::Update.apply(starting, Hive::Tui::Messages::ProjectScope.new(n: 0))
    assert_equal 0, new_model.scope
  end

  def test_noop_returns_model_unchanged
    new_model, cmd = Hive::Tui::Update.apply(model, Hive::Tui::Messages::NOOP)
    assert_same model, new_model
    assert_nil cmd
  end
end
