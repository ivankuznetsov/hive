require "test_helper"
require "hive/tui/key_map"
require "hive/tui/snapshot"

# KeyMap is the pure-data keystroke router for the TUI. These tests
# pin every action tuple shape the U5/U6 render layers depend on,
# verb-on-agent-running refusal (R11), the grid/triage `a`/`r`/`d`
# rebinding, and the curses-free key alias surface (`:key_*` symbols
# alongside `"\r"` / `"\n"` / `"\e"`).
class TuiKeyMapTest < Minitest::Test
  include HiveTestHelper

  def make_row(action_key:, suggested_command: "hive brainstorm some-slug --from 1-inbox",
               claude_pid_alive: nil, action_label: "Ready to brainstorm",
               slug: "some-slug", project_name: "alpha", stage: "1-inbox")
    Hive::Tui::Snapshot::Row.new(
      project_name: project_name,
      stage: stage,
      slug: slug,
      folder: "/tmp/hive/#{slug}",
      state_file: "/tmp/hive/#{slug}/idea.md",
      marker: "waiting",
      attrs: {},
      mtime: "2026-04-27T12:00:00Z",
      age_seconds: 1,
      claude_pid: claude_pid_alive ? 1234 : nil,
      claude_pid_alive: claude_pid_alive,
      action_key: action_key,
      action_label: action_label,
      suggested_command: suggested_command
    ).freeze
  end

  # -------- Grid mode: verb-key happy paths ------------------------

  def test_grid_verb_b_parses_suggested_command_via_shellwords
    row = make_row(action_key: "ready_to_brainstorm",
                   suggested_command: "hive plan some-slug --from 2-brainstorm")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "b", row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "plan", "some-slug", "--from", "2-brainstorm" ], payload
  end

  def test_grid_verb_capital_p_dispatches_pr
    row = make_row(action_key: "ready_for_pr",
                   suggested_command: "hive pr some-slug --from 5-review",
                   action_label: "Ready for PR")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "P", row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "pr", "some-slug", "--from", "5-review" ], payload
  end

  def test_grid_verb_passes_through_project_flag_verbatim
    row = make_row(action_key: "ready_to_plan",
                   suggested_command: "hive plan some-slug --from 2-brainstorm --project alpha")
    _, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal [ "hive", "plan", "some-slug", "--from", "2-brainstorm", "--project", "alpha" ], payload
  end

  # -------- Verb-on-agent-running refusal (R11) --------------------

  def test_grid_verb_b_on_running_agent_returns_flash
    row = make_row(action_key: "agent_running", claude_pid_alive: true,
                   action_label: "Agent running",
                   suggested_command: "hive brainstorm some-slug --from 2-brainstorm")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "b", row: row)
    assert_equal :flash, action
    assert_equal "agent is running on this task; press Enter to view its log", payload
  end

  def test_grid_verb_capital_p_on_running_agent_returns_flash
    row = make_row(action_key: "agent_running", claude_pid_alive: true,
                   action_label: "Agent running",
                   suggested_command: "hive pr some-slug --from 6-pr")
    action, _ = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "P", row: row)
    assert_equal :flash, action
  end

  def test_grid_verb_on_stale_agent_lock_dispatches_command
    row = make_row(action_key: "agent_running", claude_pid_alive: false,
                   action_label: "Agent running (stale lock)",
                   suggested_command: "hive plan some-slug --from 3-plan")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "plan", "some-slug", "--from", "3-plan" ], payload
  end

  # Lock state is unknown (nil) — must NOT route to the stale-lock
  # escape hatch. Treat unknown as "alive" so we never dispatch a verb
  # under indeterminate lock state.
  def test_grid_verb_on_unknown_pid_state_returns_flash
    row = make_row(action_key: "agent_running", claude_pid_alive: nil,
                   action_label: "Agent running",
                   suggested_command: "hive plan some-slug --from 3-plan")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal :flash, action
    assert_equal "agent is running on this task; press Enter to view its log", payload
  end

  # Stale lock with no recovery command — earlier code passed nil
  # straight to Shellwords.split and crashed; now flash a stable
  # message so the TUI keeps painting.
  def test_grid_verb_on_stale_agent_lock_without_command_returns_flash
    row = make_row(action_key: "agent_running", claude_pid_alive: false,
                   action_label: "Agent running (stale lock)",
                   suggested_command: nil)
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal :flash, action
    assert_equal "agent lock is stale but no recovery command available", payload
  end

  def test_grid_verb_on_archived_row_returns_flash_with_label
    row = make_row(action_key: "archived", suggested_command: nil,
                   action_label: "Archived")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal :flash, action
    assert_includes payload, "Archived",
                    "flash message must embed the row's action_label"
  end

  # -------- Nil row policy -----------------------------------------

  def test_grid_verb_with_nil_row_returns_noop
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: nil)
    assert_equal [ :noop, nil ], [ action, payload ]
  end

  def test_grid_q_with_nil_row_quits
    assert_equal [ :quit, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "q", row: nil)
  end

  def test_grid_help_question_with_nil_row
    assert_equal [ :help, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "?", row: nil)
  end

  def test_grid_slash_with_nil_row_filters
    assert_equal [ :filter, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "/", row: nil)
  end

  def test_grid_digit_with_nil_row_scopes_project
    assert_equal [ :project_scope, 1 ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "1", row: nil)
    assert_equal [ :project_scope, 0 ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "0", row: nil)
    assert_equal [ :project_scope, 9 ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "9", row: nil)
  end

  def test_grid_enter_with_nil_row_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: nil)
  end

  def test_grid_jk_with_nil_row_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "j", row: nil)
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "k", row: nil)
  end

  # -------- Enter dispatch on grid rows ----------------------------

  def test_grid_enter_on_review_findings_opens_findings
    row = make_row(action_key: "review_findings", suggested_command: nil,
                   action_label: "Review findings")
    assert_equal [ :open_findings, row ],
                 Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
  end

  def test_grid_enter_on_agent_running_opens_log_tail
    row = make_row(action_key: "agent_running", claude_pid_alive: true,
                   action_label: "Agent running")
    assert_equal [ :open_log_tail, row ],
                 Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
  end

  def test_grid_enter_on_needs_input_dispatches_suggested_command
    # Enter on needs_input runs the row's suggested verb (same as
    # pressing the verb keystroke for that row). The earlier
    # $EDITOR-spawn integration was removed because the alt-screen
    # handoff broke on several terminals; editing belongs in the
    # user's own shell.
    row = make_row(action_key: "needs_input",
                   suggested_command: "hive plan some-slug --project demo --from 3-plan",
                   action_label: "Needs your input")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "plan", "some-slug", "--project", "demo", "--from", "3-plan" ], payload
  end

  def test_grid_enter_on_needs_input_with_no_command_flashes
    row = make_row(action_key: "needs_input", suggested_command: nil,
                   action_label: "Needs your input")
    action, message = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :flash, action
    assert_match(/Needs your input/, message)
  end

  def test_grid_enter_on_ready_with_command_dispatches
    row = make_row(action_key: "ready_to_brainstorm",
                   suggested_command: "hive brainstorm some-slug --from 1-inbox")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "brainstorm", "some-slug", "--from", "1-inbox" ], payload
  end

  def test_grid_enter_on_archived_returns_flash
    row = make_row(action_key: "archived", suggested_command: nil,
                   action_label: "Archived")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :flash, action
    assert_equal "task is archived; no further action", payload
  end

  def test_grid_enter_on_error_returns_flash
    row = make_row(action_key: "error", suggested_command: nil,
                   action_label: "Error")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :flash, action
    assert_equal "task is in error state; inspect via $EDITOR", payload
  end

  def test_grid_enter_on_recover_execute_returns_flash
    row = make_row(action_key: "recover_execute", suggested_command: nil,
                   action_label: "Recover (execute)")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :flash, action
    assert_equal "task needs recovery — open findings to re-prioritise", payload
  end

  def test_grid_enter_on_recover_review_returns_flash
    row = make_row(action_key: "recover_review", suggested_command: nil,
                   action_label: "Recover (review)")
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
    assert_equal :flash, action
    assert_equal "task needs recovery — clear the stale review marker", payload
  end

  def test_grid_enter_accepts_carriage_return_newline_and_symbol
    row = make_row(action_key: "ready_to_brainstorm",
                   suggested_command: "hive brainstorm some-slug --from 1-inbox")
    expected = [ :dispatch_command, [ "hive", "brainstorm", "some-slug", "--from", "1-inbox" ] ]
    assert_equal expected, Hive::Tui::KeyMap.dispatch(mode: :grid, key: "\r", row: row)
    assert_equal expected, Hive::Tui::KeyMap.dispatch(mode: :grid, key: "\n", row: row)
    assert_equal expected, Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_enter, row: row)
  end

  # -------- Grid global keys ---------------------------------------

  def test_grid_slash_returns_filter
    row = make_row(action_key: "ready_to_brainstorm")
    assert_equal [ :filter, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "/", row: row)
  end

  def test_grid_question_returns_help
    row = make_row(action_key: "ready_to_brainstorm")
    assert_equal [ :help, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "?", row: row)
  end

  def test_grid_q_returns_quit
    row = make_row(action_key: "ready_to_brainstorm")
    assert_equal [ :quit, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "q", row: row)
  end

  def test_grid_digits_return_project_scope
    row = make_row(action_key: "ready_to_brainstorm")
    (0..9).each do |n|
      assert_equal [ :project_scope, n ],
                   Hive::Tui::KeyMap.dispatch(mode: :grid, key: n.to_s, row: row)
    end
  end

  def test_grid_escape_is_noop
    row = make_row(action_key: "ready_to_brainstorm")
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "\e", row: row)
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_escape, row: row)
  end

  # -------- Cursor movement ----------------------------------------

  def test_grid_jk_move_cursor
    row = make_row(action_key: "ready_to_brainstorm")
    assert_equal [ :cursor_down, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "j", row: row)
    assert_equal [ :cursor_down, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_down, row: row)
    assert_equal [ :cursor_up, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "k", row: row)
    assert_equal [ :cursor_up, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: :key_up, row: row)
  end

  def test_triage_jk_move_cursor
    row = make_row(action_key: "review_findings")
    assert_equal [ :cursor_down, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: "j", row: row)
    assert_equal [ :cursor_up, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: :key_up, row: row)
  end

  def test_log_tail_jk_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :log_tail, key: "j", row: nil)
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :log_tail, key: :key_up, row: nil)
  end

  def test_filter_jk_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :filter, key: "j", row: nil)
  end

  # -------- Triage-mode rebindings ---------------------------------

  def test_triage_a_returns_bulk_accept_with_slug
    row = make_row(action_key: "review_findings", slug: "auth-fix")
    assert_equal [ :bulk_accept, "auth-fix" ],
                 Hive::Tui::KeyMap.dispatch(mode: :triage, key: "a", row: row)
  end

  def test_triage_r_returns_bulk_reject_with_slug
    row = make_row(action_key: "review_findings", slug: "auth-fix")
    assert_equal [ :bulk_reject, "auth-fix" ],
                 Hive::Tui::KeyMap.dispatch(mode: :triage, key: "r", row: row)
  end

  def test_triage_d_synthesizes_develop_argv_from_slug
    row = make_row(action_key: "review_findings", slug: "auth-fix",
                   suggested_command: nil)
    expected = [ :dispatch_command, [ "hive", "develop", "auth-fix", "--from", "4-execute" ] ]
    assert_equal expected, Hive::Tui::KeyMap.dispatch(mode: :triage, key: "d", row: row)
  end

  def test_triage_space_string_returns_toggle_finding
    row = make_row(action_key: "review_findings")
    assert_equal [ :toggle_finding, row ],
                 Hive::Tui::KeyMap.dispatch(mode: :triage, key: " ", row: row)
  end

  def test_triage_space_symbol_returns_toggle_finding
    row = make_row(action_key: "review_findings")
    assert_equal [ :toggle_finding, row ],
                 Hive::Tui::KeyMap.dispatch(mode: :triage, key: :space, row: row)
  end

  def test_triage_space_with_nil_row_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: " ", row: nil)
  end

  def test_triage_q_is_noop_not_quit
    row = make_row(action_key: "review_findings")
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: "q", row: row)
  end

  def test_triage_unknown_key_is_noop
    row = make_row(action_key: "review_findings")
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: "x", row: row)
  end

  # -------- Esc / back semantics across modes ----------------------

  def test_escape_in_grid_is_noop
    assert_equal [ :noop, nil ], Hive::Tui::KeyMap.dispatch(mode: :grid, key: "\e", row: nil)
  end

  def test_escape_in_triage_returns_back
    assert_equal [ :back, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: "\e", row: nil)
    assert_equal [ :back, nil ], Hive::Tui::KeyMap.dispatch(mode: :triage, key: :key_escape, row: nil)
  end

  def test_escape_in_log_tail_returns_back
    assert_equal [ :back, nil ], Hive::Tui::KeyMap.dispatch(mode: :log_tail, key: "\e", row: nil)
  end

  def test_q_in_log_tail_returns_back
    assert_equal [ :back, nil ], Hive::Tui::KeyMap.dispatch(mode: :log_tail, key: "q", row: nil)
  end

  def test_escape_in_filter_returns_back
    assert_equal [ :back, nil ], Hive::Tui::KeyMap.dispatch(mode: :filter, key: "\e", row: nil)
  end

  # -------- Argument validation ------------------------------------

  def test_unknown_mode_raises_argument_error
    err = assert_raises(ArgumentError) do
      Hive::Tui::KeyMap.dispatch(mode: :nonsense, key: "q", row: nil)
    end
    assert_includes err.message, "nonsense",
                    "error must name the offending mode"
  end

  # Argv round-trip safety: a project name carrying shell metacharacters
  # (here, a quoted "; rm -rf ~" payload) must surface as a single inert
  # literal argv element after Shellwords.split — never an interpreted
  # command. `Process.spawn(*argv)` doesn't go through a shell, so as long
  # as the splitter respects the quoting, the metacharacter stays a
  # data byte rather than control flow.
  def test_grid_verb_preserves_shell_metacharacters_in_project_arg
    suggested = "hive plan some-slug --project '; rm -rf ~' --from 2-brainstorm"
    row = make_row(action_key: "ready_to_plan", suggested_command: suggested)
    action, payload = Hive::Tui::KeyMap.dispatch(mode: :grid, key: "p", row: row)
    assert_equal :dispatch_command, action
    assert_equal [ "hive", "plan", "some-slug", "--project", "; rm -rf ~", "--from", "2-brainstorm" ],
                 payload,
                 "shell metacharacter must round-trip as an inert literal argv element"
  end
end
