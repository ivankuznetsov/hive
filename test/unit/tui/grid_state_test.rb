require "test_helper"
require "hive/tui/grid_state"
require "hive/tui/snapshot"

# GridState owns the per-frame view state (cursor, filter, scope,
# flash). These tests pin the cursor wrap/clamp rules across project
# boundaries, the filter/scope cursor reset semantics from the plan
# (lines 548–553), the empty-grid → cursor=nil contract, and the
# flash TTL decay. All scenarios build Snapshots directly via
# `Snapshot.from_payload` so the tests are deterministic and don't
# need a real `hive status` registry.
class TuiGridStateTest < Minitest::Test
  include HiveTestHelper

  def make_task(slug:, action: "ready_to_brainstorm")
    {
      "stage" => "1-inbox",
      "slug" => slug,
      "folder" => "/tmp/hive/#{slug}",
      "state_file" => "/tmp/hive/#{slug}/idea.md",
      "marker" => "waiting",
      "attrs" => {},
      "mtime" => "2026-04-27T12:00:00Z",
      "age_seconds" => 1,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => "Ready to brainstorm",
      "suggested_command" => "hive brainstorm #{slug}"
    }
  end

  def make_project(name, slugs)
    {
      "name" => name,
      "path" => "/tmp/#{name}",
      "hive_state_path" => "/tmp/#{name}/.hive-state",
      "tasks" => slugs.map { |s| make_task(slug: s) }
    }
  end

  def make_snapshot(projects)
    Hive::Tui::Snapshot.from_payload(
      "schema" => "hive-status",
      "schema_version" => 1,
      "generated_at" => "2026-04-27T12:00:00Z",
      "projects" => projects
    )
  end

  # -------- Defaults -----------------------------------------------

  def test_defaults_to_origin_cursor_no_filter_no_scope
    state = Hive::Tui::GridState.new
    assert_equal [ 0, 0 ], state.cursor
    assert_nil state.filter
    assert_equal 0, state.scope
    assert_nil state.flash_message
  end

  # -------- j / k movement within and across projects --------------

  def test_j_increments_row_idx_within_project
    snapshot = make_snapshot([ make_project("alpha", %w[a1 a2 a3]) ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    assert_equal [ 0, 1 ], state.cursor
    state.move_cursor_down(snapshot)
    assert_equal [ 0, 2 ], state.cursor
  end

  def test_k_decrements_row_idx_within_project
    snapshot = make_snapshot([ make_project("alpha", %w[a1 a2 a3]) ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    state.move_cursor_down(snapshot)
    state.move_cursor_up(snapshot)
    assert_equal [ 0, 1 ], state.cursor
  end

  def test_j_past_last_row_of_project_a_jumps_to_first_row_of_project_b
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2]),
                               make_project("beta",  %w[b1 b2])
                             ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot) # [0,1]
    state.move_cursor_down(snapshot) # [1,0] — boundary cross
    assert_equal [ 1, 0 ], state.cursor
  end

  def test_j_past_last_row_of_last_project_clamps_at_last_row
    snapshot = make_snapshot([ make_project("alpha", %w[a1 a2]) ])
    state = Hive::Tui::GridState.new
    5.times { state.move_cursor_down(snapshot) }
    assert_equal [ 0, 1 ], state.cursor, "j should clamp at last row of last project"
  end

  def test_k_past_first_row_clamps_at_origin
    snapshot = make_snapshot([ make_project("alpha", %w[a1 a2]) ])
    state = Hive::Tui::GridState.new
    5.times { state.move_cursor_up(snapshot) }
    assert_equal [ 0, 0 ], state.cursor
  end

  def test_k_at_top_of_project_b_jumps_to_last_row_of_project_a
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2 a3]),
                               make_project("beta",  %w[b1])
                             ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot) # [0,1]
    state.move_cursor_down(snapshot) # [0,2]
    state.move_cursor_down(snapshot) # [1,0]
    state.move_cursor_up(snapshot)   # back to [0,2]
    assert_equal [ 0, 2 ], state.cursor
  end

  def test_j_skips_empty_project_in_the_middle
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1]),
                               make_project("empty", []),
                               make_project("gamma", %w[g1])
                             ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    # Skips over the empty middle project entirely so the cursor lands
    # on the next project with rows. project_idx is the visible-snapshot
    # index, which still includes the empty project, so we expect 2.
    assert_equal [ 2, 0 ], state.cursor
  end

  # -------- Empty grid ---------------------------------------------

  def test_empty_grid_yields_nil_cursor_after_filter_set
    snapshot = make_snapshot([])
    state = Hive::Tui::GridState.new
    state.set_filter(nil, snapshot)
    assert_nil state.cursor
    assert_nil state.at_cursor(snapshot)
  end

  def test_at_cursor_with_default_cursor_against_empty_snapshot_is_nil
    snapshot = make_snapshot([])
    state = Hive::Tui::GridState.new
    # Default cursor [0,0] is fine; at_cursor still returns nil because
    # row_at is out-of-range — exercising the safety net.
    assert_nil state.at_cursor(snapshot)
  end

  # -------- Filter cursor semantics --------------------------------

  def test_filter_narrowing_to_zero_rows_globally_makes_cursor_nil
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2]),
                               make_project("beta",  %w[b1])
                             ])
    state = Hive::Tui::GridState.new
    state.set_filter("zzz-no-match", snapshot)
    assert_nil state.cursor
    assert_nil state.at_cursor(snapshot)
  end

  def test_filter_narrowing_current_project_to_zero_jumps_to_next_match
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2]),
                               make_project("beta",  %w[bug-fix b1])
                             ])
    state = Hive::Tui::GridState.new
    # "bug" only matches the second project — cursor should jump there.
    state.set_filter("bug", snapshot)
    assert_equal [ 1, 0 ], state.cursor
    row = state.at_cursor(snapshot)
    refute_nil row
    assert_equal "bug-fix", row.slug
  end

  def test_clearing_filter_resets_cursor_to_origin
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2]),
                               make_project("beta",  %w[b1])
                             ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    state.move_cursor_down(snapshot)
    state.set_filter("", snapshot)
    assert_equal [ 0, 0 ], state.cursor, "Esc/empty filter resets to first project's first row"
  end

  def test_clearing_filter_with_nil_resets_cursor_to_origin
    snapshot = make_snapshot([ make_project("alpha", %w[a1 a2]) ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    state.set_filter(nil, snapshot)
    assert_equal [ 0, 0 ], state.cursor
  end

  # -------- Scope cursor semantics ---------------------------------

  def test_set_scope_to_project_n_resets_cursor_to_origin
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 a2]),
                               make_project("beta",  %w[b1 b2 b3])
                             ])
    state = Hive::Tui::GridState.new
    state.move_cursor_down(snapshot)
    state.set_scope(2, snapshot)
    # After scope_to_project_index(2), beta sits at index 0.
    assert_equal [ 0, 0 ], state.cursor
    row = state.at_cursor(snapshot)
    assert_equal "b1", row.slug
  end

  def test_set_scope_zero_clears_and_resets_cursor_to_origin
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1]),
                               make_project("beta",  %w[b1])
                             ])
    state = Hive::Tui::GridState.new
    state.set_scope(2, snapshot)
    state.set_scope(0, snapshot)
    assert_equal [ 0, 0 ], state.cursor
  end

  def test_set_scope_out_of_range_yields_nil_cursor
    snapshot = make_snapshot([ make_project("alpha", %w[a1]) ])
    state = Hive::Tui::GridState.new
    state.set_scope(99, snapshot)
    assert_nil state.cursor
  end

  # -------- visible_snapshot composition ---------------------------

  def test_visible_snapshot_applies_scope_then_filter
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1 auth-fix]),
                               make_project("beta",  %w[auth-fix b1])
                             ])
    state = Hive::Tui::GridState.new
    state.set_scope(2, snapshot)        # narrow to beta
    state.set_filter("auth", snapshot)  # then filter inside it
    visible = state.visible_snapshot(snapshot)
    assert_equal 1, visible.projects.size
    assert_equal "beta", visible.projects.first.name
    assert_equal [ "auth-fix" ], visible.projects.first.rows.map(&:slug)
  end

  # -------- at_cursor against scope+filter -------------------------

  def test_at_cursor_returns_row_against_scope_and_filter_applied_snapshot
    snapshot = make_snapshot([
                               make_project("alpha", %w[a1]),
                               make_project("beta",  %w[bug-1 bug-2 noise])
                             ])
    state = Hive::Tui::GridState.new
    state.set_scope(2, snapshot)
    state.set_filter("bug", snapshot)
    state.move_cursor_down(snapshot)
    row = state.at_cursor(snapshot)
    assert_equal "bug-2", row.slug
  end

  # -------- Flash message decay ------------------------------------

  def test_flash_sets_message_and_is_active_within_ttl
    state = Hive::Tui::GridState.new
    t0 = Time.utc(2026, 4, 27, 12, 0, 0)
    state.flash!("hello", now: t0)
    assert_equal "hello", state.flash_message
    assert state.flash_active?(now: t0 + 1.0), "active 1s after set"
    assert state.flash_active?(now: t0 + 4.99), "active just under 5s ttl"
  end

  def test_flash_decays_after_default_ttl
    state = Hive::Tui::GridState.new
    t0 = Time.utc(2026, 4, 27, 12, 0, 0)
    state.flash!("bye", now: t0)
    refute state.flash_active?(now: t0 + 5.01), "expired just after 5s ttl"
    refute state.flash_active?(now: t0 + 60), "expired well past ttl"
  end

  def test_flash_active_false_when_never_set
    state = Hive::Tui::GridState.new
    refute state.flash_active?
  end

  def test_flash_active_respects_custom_ttl
    state = Hive::Tui::GridState.new
    t0 = Time.utc(2026, 4, 27, 12, 0, 0)
    state.flash!("x", now: t0)
    assert state.flash_active?(now: t0 + 9.0, ttl_seconds: 10.0)
    refute state.flash_active?(now: t0 + 11.0, ttl_seconds: 10.0)
  end
end
