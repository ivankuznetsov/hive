require "test_helper"
require "fileutils"
require "tmpdir"
require "hive/tui/key_map"
require "hive/tui/snapshot"

# `KeyMap.message_for(mode:, key:, row:) → Hive::Tui::Messages::*` is
# the only public dispatch surface after U11; the legacy `dispatch`
# tuple shim was deleted alongside the curses backend. Tests pin the
# Message shapes directly. The discriminative-power audit (ADV-2 from
# the doc review) focuses on branches where the same key produces
# different shapes based on row state: agent_running's three sub-paths,
# stale-lock escape hatch, contextual Enter dispatch.
class TuiKeyMapMessageForTest < Minitest::Test
  include HiveTestHelper

  def make_row(action_key:, suggested_command: "hive brainstorm some-slug --from 1-inbox",
               claude_pid_alive: nil, action_label: "Ready to brainstorm",
               slug: "some-slug", project_name: "alpha", stage: "1-inbox",
               folder: nil, marker: "waiting", attrs: {}, next_action: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: project_name, stage: stage, slug: slug,
      folder: folder || "/tmp/hive/#{slug}",
      state_file: "/tmp/hive/#{slug}/idea.md",
      marker: marker, attrs: attrs, mtime: "2026-04-27T12:00:00Z", age_seconds: 1,
      claude_pid: claude_pid_alive ? 1234 : nil, claude_pid_alive: claude_pid_alive,
      action_key: action_key, action_label: action_label,
      suggested_command: suggested_command, next_action: next_action, diagnostic: nil
    ).freeze
  end

  # -------- DispatchCommand caches verb at construction --------

  def test_dispatch_command_caches_verb_from_argv
    # The plan calls out that DispatchCommand.verb is cached so
    # SubprocessExited can flash by verb name without re-parsing.
    row = make_row(action_key: "ready_to_plan",
                   suggested_command: "hive plan some-slug --from 2-brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal "plan", msg.verb, "verb must be argv[1] cached at construction"
    assert_equal [ "hive", "plan", "some-slug", "--from", "2-brainstorm" ], msg.argv
  end

  # -------- Agent_running's three sub-paths (ADV-2 discriminative coverage) --------

  def test_agent_running_with_alive_pid_returns_flash_refusal
    row = make_row(action_key: "agent_running", claude_pid_alive: true,
                   suggested_command: nil, action_label: "Agent running")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_match(/agent is running/, msg.text)
  end

  def test_agent_running_with_nil_pid_alive_returns_flash_refusal
    # Indeterminate lock state — never dispatches, never crashes.
    row = make_row(action_key: "agent_running", claude_pid_alive: nil,
                   suggested_command: nil, action_label: "Agent running")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_match(/agent is running/, msg.text)
  end

  def test_agent_running_stale_lock_with_no_command_flashes_recovery_hint
    # Stale-lock escape hatch but suggested_command is nil — must flash
    # a recovery hint instead of crashing on Shellwords.split(nil).
    row = make_row(action_key: "agent_running", claude_pid_alive: false,
                   suggested_command: nil, action_label: "Agent running")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_match(/stale.*no recovery command/, msg.text)
  end

  def test_agent_running_stale_lock_with_command_dispatches
    # Stale-lock escape hatch with a non-nil suggested_command —
    # dispatches the verb so Hive::Lock can reap the stale lock.
    row = make_row(action_key: "agent_running", claude_pid_alive: false,
                   suggested_command: "hive plan some-slug --from 2-brainstorm",
                   action_label: "Agent running")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal "plan", msg.verb
  end

  # -------- v2 pane focus + new-idea bindings --------

  def test_grid_tab_returns_pane_focus_toggled
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_tab, row: nil)
    assert_same Hive::Tui::Messages::PANE_FOCUS_TOGGLED, msg
  end

  def test_grid_backtab_also_toggles_pane_focus
    # `Shift+Tab` on most terminals surfaces as `:key_backtab` in
    # Bubble Tea. Both keys should drive the same toggle.
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_backtab, row: nil)
    assert_same Hive::Tui::Messages::PANE_FOCUS_TOGGLED, msg
  end

  def test_grid_h_jumps_pane_focus_to_left
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "h", row: nil)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :left, msg.target
  end

  def test_grid_key_left_jumps_pane_focus_to_left
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_left, row: nil)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :left, msg.target
  end

  def test_grid_l_jumps_pane_focus_to_right
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "l", row: nil)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :right, msg.target
  end

  def test_grid_key_right_jumps_pane_focus_to_right
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_right, row: nil)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :right, msg.target
  end

  def test_grid_n_opens_new_idea_prompt
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "n", row: nil)
    assert_same Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT, msg
  end

  # ---- v2 g/G jump-to-top/bottom (Plan R4 stretch nav) ----

  def test_grid_lowercase_g_returns_cursor_jump_top_singleton
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "g", row: nil)
    assert_same Hive::Tui::Messages::CURSOR_JUMP_TOP, msg
  end

  def test_grid_uppercase_G_returns_cursor_jump_bottom_singleton
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "G", row: nil)
    assert_same Hive::Tui::Messages::CURSOR_JUMP_BOTTOM, msg
  end

  # ---- `o` opens task folder (read-only browse, no workflow dispatch) ----

  def test_grid_o_with_row_returns_open_task_folder
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "o", row: row)
    assert_kind_of Hive::Tui::Messages::OpenTaskFolder, msg
    assert_equal row, msg.row
  end

  def test_grid_o_with_nil_row_is_noop
    # The nil-row guard at line 114 of key_map.rb covers this case
    # uniformly — `o` never tries to construct an OpenTaskFolder with
    # a missing row. Empty-folder refusal lives at the BubbleModel
    # handler level (U2) so it can flash, not silently NOOP.
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "o", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_grid_i_with_row_returns_open_idea_preview
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "i", row: row)

    assert_kind_of Hive::Tui::Messages::OpenIdeaPreview, msg
    assert_equal row, msg.row
  end

  def test_grid_i_with_nil_row_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "i", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_grid_i_with_left_pane_focus_is_noop
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "i", row: row, pane_focus: :left)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_grid_s_with_row_returns_open_in_agent
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "s", row: row)
    assert_kind_of Hive::Tui::Messages::OpenInAgent, msg
    assert_equal row, msg.row
  end

  def test_grid_s_with_nil_suggested_command_still_returns_open_in_agent
    row = make_row(action_key: "error", suggested_command: nil, action_label: "Error")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "s", row: row)
    assert_kind_of Hive::Tui::Messages::OpenInAgent, msg
    assert_equal row, msg.row
  end

  def test_grid_s_with_nil_row_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "s", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_grid_s_with_left_pane_focus_is_noop
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "s", row: row, pane_focus: :left)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Mirror-pair guard: `o`, `i`, and `s` are the row-bound
  # browse/preview/steer gestures in grid mode. All three must NOOP on
  # the left (scope) pane so an operator who jumped focus to pick a
  # project cannot accidentally fire any of them against the row under
  # the right pane's cursor without first returning focus.
  def test_grid_o_with_left_pane_focus_is_noop
    row = make_row(action_key: "ready_to_plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "o", row: row, pane_focus: :left)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Regression guard: a MANUAL_STEERING row has no `suggested_command`
  # (the row is non-actionable in the workflow sense — the agent is the
  # human steering it). Verb keys on such a row must fall through to the
  # generic "no action available" flash. Without this assertion, a
  # future change that wired a command back onto `:manual_steering` in
  # `TaskAction::ACTIONS` would silently dispatch a workflow verb
  # against a manually-steered task.
  def test_grid_verb_on_manual_steering_row_returns_no_action_flash
    row = make_row(action_key: "manual_steering", action_label: "Manually steered",
                   marker: "manual_steering", suggested_command: nil)
    %w[b p d r P F a].each do |key|
      msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: key, row: row)
      assert_kind_of Hive::Tui::Messages::Flash, msg,
        "`#{key}` on a manual_steering row must flash, not dispatch"
      assert_match(/no action available/, msg.text,
        "`#{key}` flash on a manual_steering row should be the generic refusal")
    end
  end

  def test_new_idea_o_continues_to_emit_text_inserted
    # Mode isolation R7: in :new_idea mode the `o` key still routes
    # through new_idea_message as a printable character, not the new
    # grid-only OpenTaskFolder branch.
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: "o", row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaTextInserted, msg
    assert_equal "o", msg.text
  end

  def test_new_idea_i_continues_to_emit_text_inserted
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: "i", row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaTextInserted, msg
    assert_equal "i", msg.text
  end

  def test_filter_o_continues_to_emit_char_appended
    # Mode isolation R7: in :filter mode the `o` key still routes
    # through filter_message as a printable character.
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: "o", row: nil)
    assert_kind_of Hive::Tui::Messages::FilterCharAppended, msg
    assert_equal "o", msg.char
  end

  def test_filter_i_continues_to_emit_filter_char_appended
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: "i", row: nil)
    assert_kind_of Hive::Tui::Messages::FilterCharAppended, msg
    assert_equal "i", msg.char
  end

  def test_idea_preview_any_key_returns_back
    [ "i", "x", :key_enter, :key_escape, "q", :space ].each do |key|
      msg = Hive::Tui::KeyMap.message_for(mode: :idea_preview, key: key, row: nil)
      assert_same Hive::Tui::Messages::BACK, msg, "#{key.inspect} must dismiss idea preview"
    end
  end

  def test_log_tail_o_is_noop
    # Mode isolation R7: in :log_tail mode the `o` key falls through
    # to NOOP (only q/Esc are bound — back to grid). Pins that
    # :log_tail doesn't accidentally route `o` to grid-mode dispatch.
    msg = Hive::Tui::KeyMap.message_for(mode: :log_tail, key: "o", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_log_tail_s_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :log_tail, key: "s", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # ---- :new_idea mode keystroke routing ----

  def test_new_idea_esc_cancels
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_escape, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CANCELLED, msg
  end

  def test_new_idea_enter_submits
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_enter, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_SUBMITTED, msg
  end

  def test_new_idea_backspace_deletes
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_backspace, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED, msg
  end

  def test_new_idea_printable_char_appends
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: "r", row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaTextInserted, msg
    assert_equal "r", msg.text
  end

  def test_new_idea_cursor_keys_route_to_prompt_navigation
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_LEFT,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_left, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_RIGHT,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_right, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_HOME,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_home, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_END,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_end, row: nil)
  end

  def test_new_idea_ctrl_a_and_ctrl_e_route_to_home_and_end
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_HOME,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_ctrl_a, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CURSOR_END,
      Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_ctrl_e, row: nil)
  end

  def test_new_idea_ctrl_v_emits_paste_requested_with_empty_text
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_ctrl_v, row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaPasteRequested, msg
    assert_equal "", msg.raw_text
  end

  def test_grid_ctrl_v_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_ctrl_v, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_filter_ctrl_v_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_ctrl_v, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_help_ctrl_v_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :help, key: :key_ctrl_v, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_help_regular_key_returns_back
    msg = Hive::Tui::KeyMap.message_for(mode: :help, key: "?", row: nil)
    assert_same Hive::Tui::Messages::BACK, msg
  end

  def test_new_idea_delete_routes_to_forward_delete
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_delete, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CHAR_DELETED_FORWARD, msg
  end

  def test_new_idea_unbound_grid_navigation_key_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_up, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Regression: BubbleModel#bubble_key_to_keymap emits `:space` for the
  # SPACE key, but printable_filter_char? returns false for symbols.
  # Without an explicit branch, multi-word titles like "rss feeds"
  # would land as "rssfeeds" in the buffer.
  def test_new_idea_space_symbol_appends_literal_space
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :space, row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaTextInserted, msg
    assert_equal " ", msg.text
  end

  def test_new_idea_project_picker_keys_choose_move_and_cancel
    assert_same Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED,
      Hive::Tui::KeyMap.message_for(mode: :new_idea_project, key: :key_enter, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_DOWN,
      Hive::Tui::KeyMap.message_for(mode: :new_idea_project, key: "j", row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_UP,
      Hive::Tui::KeyMap.message_for(mode: :new_idea_project, key: :key_up, row: nil)
    assert_same Hive::Tui::Messages::NEW_IDEA_CANCELLED,
      Hive::Tui::KeyMap.message_for(mode: :new_idea_project, key: "q", row: nil)
  end

  def test_new_idea_project_unknown_key_returns_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea_project, key: "x", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Same regression for filter mode — slug filters with spaces like
  # "rss feeds" must work too.
  def test_filter_space_symbol_appends_literal_space
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :space, row: nil)
    assert_kind_of Hive::Tui::Messages::FilterCharAppended, msg
    assert_equal " ", msg.char
  end

  def test_filter_left_and_right_keys_are_noop
    assert_same Hive::Tui::Messages::NOOP,
      Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_left, row: nil)
    assert_same Hive::Tui::Messages::NOOP,
      Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_right, row: nil)
  end

  def test_grid_enter_from_left_pane_jumps_focus_to_right
    # On the left pane Enter is "select project, focus tasks" — never
    # a verb dispatch. KeyMap routes this without consulting `row`.
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: nil, pane_focus: :left)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :right, msg.target
  end

  def test_grid_enter_from_right_pane_falls_through_to_existing_dispatch
    # On the right pane Enter still routes via enter_message(row) →
    # DispatchCommand for ready_* rows (existing v1 behaviour). Pin it
    # so a future refactor doesn't accidentally route Enter through
    # the pane-focus branch on the right.
    row = Hive::Tui::Snapshot::Row.new(
      project_name: "p", stage: "2-brainstorm", slug: "s", folder: "/f",
      state_file: "/s.md", marker: "complete", attrs: {}, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "ready_to_plan", action_label: "Ready to plan",
      suggested_command: "hive plan s --from 2-brainstorm", next_action: nil, diagnostic: nil
    )
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row, pane_focus: :right)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
  end

  def test_message_for_pane_focus_defaults_to_right_for_back_compat
    # Existing callers that don't pass `pane_focus:` (any v1 unit test
    # in the suite) must continue to work — default :right preserves
    # v1 KeyMap behaviour.
    row = Hive::Tui::Snapshot::Row.new(
      project_name: "p", stage: "2-brainstorm", slug: "s", folder: "/f",
      state_file: "/s.md", marker: "complete", attrs: {}, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "ready_to_plan", action_label: "Ready to plan",
      suggested_command: "hive plan s --from 2-brainstorm", next_action: nil, diagnostic: nil
    )
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
  end

  def test_enter_on_execute_waiting_run_next_action_dispatches_rerun
    row = make_row(
      action_key: "needs_input",
      action_label: "Needs your input",
      stage: "4-execute",
      marker: "execute_waiting",
      attrs: { "reason" => "missing_research_output" },
      suggested_command: "hive develop some-slug --from 4-execute",
      next_action: {
        "kind" => Hive::Schemas::NextActionKind::RUN,
        "target" => "/tmp/hive/some-slug"
      }
    )

    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)

    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal [ "hive", "develop", "some-slug", "--from", "4-execute" ], msg.argv
  end

  # -------- Mode globals (work without a row) --------

  def test_grid_q_returns_terminate_requested
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "q", row: nil)
    assert_same Hive::Tui::Messages::TERMINATE_REQUESTED, msg
  end

  def test_grid_help_returns_show_help_singleton
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "?", row: nil)
    assert_same Hive::Tui::Messages::SHOW_HELP, msg
  end

  def test_grid_slash_returns_open_filter_prompt_singleton
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "/", row: nil)
    assert_same Hive::Tui::Messages::OPEN_FILTER_PROMPT, msg
  end

  def test_grid_digit_returns_project_scope_with_n
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "3", row: nil)
    assert_kind_of Hive::Tui::Messages::ProjectScope, msg
    assert_equal 3, msg.n
  end

  def test_grid_zero_returns_project_scope_clear
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "0", row: nil)
    assert_kind_of Hive::Tui::Messages::ProjectScope, msg
    assert_equal 0, msg.n
  end

  # -------- Cursor navigation --------

  def test_grid_j_returns_cursor_down_singleton
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "j", row: row)
    assert_same Hive::Tui::Messages::CURSOR_DOWN, msg
  end

  def test_grid_key_up_returns_cursor_up_singleton
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_up, row: row)
    assert_same Hive::Tui::Messages::CURSOR_UP, msg
  end

  # Cursor navigation must work when the cursor sits on no visible row
  # (post-filter-commit, post-snapshot-poll, or boot before any cursor
  # has been derived). Without this, j/k after a filter that hid the
  # selected row returned NOOP and wedged the user with visible matches
  # they couldn't navigate to.
  def test_grid_j_returns_cursor_down_even_when_row_is_nil
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "j", row: nil)
    assert_same Hive::Tui::Messages::CURSOR_DOWN, msg
  end

  def test_grid_k_returns_cursor_up_even_when_row_is_nil
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "k", row: nil)
    assert_same Hive::Tui::Messages::CURSOR_UP, msg
  end

  def test_grid_arrow_keys_returns_cursor_messages_when_row_is_nil
    down = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_down, row: nil)
    up = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_up, row: nil)
    assert_same Hive::Tui::Messages::CURSOR_DOWN, down
    assert_same Hive::Tui::Messages::CURSOR_UP, up
  end

  def test_grid_verb_keystroke_still_noops_when_row_is_nil
    # The reverse-defense: verbs need a row to dispatch. row.nil must
    # still NOOP for verb / Enter keystrokes; only cursor navigation
    # bypasses the row guard.
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "b", row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # -------- Enter sub-mode dispatch --------

  # Plan U8: Enter on a completed 8-finalize row routes to `OpenSummary`
  # so the operator can browse `summary.md` from the TUI without falling
  # out to a shell. The branch in KeyMap#enter_message gates on
  # `stage == "8-finalize" && marker == "complete"`; any other stage or
  # marker falls through to the existing dispatch table.
  def test_enter_on_finalize_complete_row_returns_open_summary
    row = make_row(action_key: "ready_to_archive", action_label: "Ready to archive",
                   stage: "8-finalize", marker: "complete", suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenSummary, msg
    assert_same row, msg.row
  end

  def test_enter_on_finalize_non_complete_row_does_not_return_open_summary
    # Sibling guard: only the marker=="complete" branch routes to
    # OpenSummary. A row mid-finalize (e.g. agent_running) must still
    # take the agent_running branch, not the summary viewer.
    row = make_row(action_key: "agent_running", action_label: "Agent running",
                   stage: "8-finalize", marker: "agent_working",
                   claude_pid_alive: true, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    refute_kind_of Hive::Tui::Messages::OpenSummary, msg
  end

  def test_enter_on_agent_running_returns_open_log_tail_with_row
    row = make_row(action_key: "agent_running", action_label: "Agent running",
                   claude_pid_alive: true, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenLogTail, msg
    assert_same row, msg.row
  end

  # Enter on an error-state row with a non-kill-class exit code now
  # opens the red-status detail view first. The detail view's Enter
  # key still routes to RecoverError, but only after the operator sees
  # the diagnosis and explicit action choices.
  def test_enter_on_error_with_real_failure_opens_red_status_detail
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenRedStatusDetail, msg
    assert_same row, msg.row
  end

  # Kill-class signal kills (130/137/143) are auto-healed in the
  # background by BubbleModel; while the heal is in flight, KeyMap falls
  # back to OpenLogTail so the user can read the kill context. An
  # Enter-driven RecoverError on those rows would race the auto-healer
  # for the same markers-lock and is intentionally avoided.
  def test_enter_on_error_with_kill_class_exit_code_returns_open_log_tail
    %w[130 137 143].each do |code|
      row = make_row(action_key: "error", action_label: "Error",
                     marker: "error", attrs: { "reason" => "exit_code", "exit_code" => code },
                     suggested_command: nil)
      msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
      assert_kind_of Hive::Tui::Messages::OpenLogTail, msg,
        "Enter on a kill-class (exit_code=#{code}) error row must defer to log tail; " \
        "the auto-healer owns the markers-clear and Enter would race it"
      assert_same row, msg.row
    end
  end

  # ERROR markers without an `exit_code` attr (legacy or hand-written)
  # take the recovery path because there is no other gesture available
  # and `hive markers clear --name ERROR` accepts them.
  def test_enter_on_error_without_exit_code_opens_red_status_detail
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenRedStatusDetail, msg
    assert_same row, msg.row
  end

  def test_error_message_non_kill_class_returns_recover_error
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.error_message(row)
    assert_kind_of Hive::Tui::Messages::RecoverError, msg
    assert_same row, msg.row
  end

  def test_enter_on_recover_review_opens_red_status_detail
    row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                   marker: "review_error", attrs: { "phase" => "fix", "pass" => "1" },
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenRedStatusDetail, msg
    assert_same row, msg.row
  end

  def test_enter_on_recover_execute_opens_red_status_detail
    # EXECUTE_STALE rows previously had no TUI detail view even though
    # they emit `diagnostic` in JSON. Opening the view here gives the
    # operator the same bounded summary + artifact tail + R-refresh
    # primitives that recover_review / error rows have. See PR #84
    # review finding #10.
    row = make_row(action_key: "recover_execute", action_label: "Needs recovery",
                   stage: "4-execute", marker: "execute_stale",
                   attrs: { "pass" => "2" }, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenRedStatusDetail, msg
    assert_same row, msg.row
  end

  def test_enter_on_archived_row_flashes_archived_message
    row = make_row(action_key: "archived", action_label: "Archived", suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_match(/task is archived/, msg.text)
  end

  def test_enter_on_unmapped_row_without_command_returns_noop
    row = make_row(action_key: "unknown_action", action_label: "Unknown", suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_enter_on_wall_clock_review_stale_keeps_direct_recover_review
    row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                   stage: "6-review", marker: "review_stale",
                   attrs: { "reason" => "wall_clock", "pass" => "1" },
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::RecoverReview, msg
    refute msg.force
  end

  def test_enter_on_max_passes_review_stale_with_escalations_keeps_browse_path
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "escalations-04.md"), "## pass 4\n")
      row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                     stage: "6-review", marker: "review_stale", folder: dir,
                     attrs: { "pass" => "4" }, suggested_command: nil)

      msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)

      assert_kind_of Hive::Tui::Messages::RecoverReview, msg
      refute msg.force
    end
  end

  def test_r_verb_on_max_passes_hit_review_stale_force_retries
    # `r` (review verb) on a max_passes-hit REVIEW_STALE row is the
    # explicit "I edited the escalations file, retry now" gesture.
    # `suggested_command` is nil for this row state (Hive::TaskAction
    # returns no command for review_stale max_passes-hit), so the
    # previous behavior was a "no action available" flash. The new
    # path emits RecoverReview with force=true so BubbleModel bypasses
    # the retryable_review_stale? gate.
    row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                   stage: "5-review", marker: "review_stale",
                   attrs: { "pass" => "4" }, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "r", row: row)
    assert_kind_of Hive::Tui::Messages::RecoverReview, msg
    assert_same row, msg.row
    assert msg.force, "`r` on max_passes-hit REVIEW_STALE sets force=true"
  end

  def test_other_verbs_on_max_passes_hit_review_stale_still_flash_no_action
    # Only `r` (semantically a retry of the review stage) takes the
    # force-retry path. Other verbs on the same row keep flashing
    # "no action available" because dispatching brainstorm/plan/develop/pr
    # on a stale review row would be wrong.
    row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                   stage: "5-review", marker: "review_stale",
                   attrs: { "pass" => "4" }, suggested_command: nil)
    [ "b", "p", "d", "P" ].each do |key|
      msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: key, row: row)
      assert_kind_of Hive::Tui::Messages::Flash, msg,
                     "verb `#{key}` on max_passes-hit REVIEW_STALE must flash, not force-retry (got #{msg.class})"
      assert_match(/no action available/, msg.text)
    end
  end

  def test_r_verb_on_non_review_stale_recover_row_keeps_flash
    # `r` on a recover_review row whose marker is NOT review_stale
    # (e.g., review_error from a programmer-error escape) should NOT
    # force-retry — review_error has its own routing via Enter →
    # RecoverError. The force-retry path is REVIEW_STALE-specific.
    row = make_row(action_key: "recover_review", action_label: "Needs recovery",
                   stage: "5-review", marker: "review_error",
                   attrs: { "phase" => "fix", "reason" => "fix_failed" },
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "r", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_match(/no action available/, msg.text)
  end

  def test_red_status_detail_enter_dispatches_autofix
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::RedStatusAutofix, msg
    assert_same row, msg.row
  end

  def test_red_status_detail_keys_route_to_recover_open_in_agent_and_back
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)

    open_msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "o", row: row)
    assert_kind_of Hive::Tui::Messages::OpenInAgent, open_msg
    assert_same row, open_msg.row

    assert_same Hive::Tui::Messages::BACK,
      Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "q", row: row)
    assert_same Hive::Tui::Messages::BACK,
      Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_escape, row: row)

    # `f` (old manual-fix) and `R` (old refresh-diagnosis) flash a
    # refusal hint rather than silently NOOP so a muscle-memory drift
    # surfaces the new contract instead of returning no signal.
    f_msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "f", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, f_msg

    r_msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "R", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, r_msg
  end

  def test_red_status_detail_s_key_flashes_use_o_hint
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)

    msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "s", row: row)

    assert_kind_of Hive::Tui::Messages::Flash, msg
    # Pin the exact s-key copy so the s-key-specific nudge stays
    # divergent from the generic f/R refusal — a regression that
    # collapses both into `red_status_detail_hint` would slip through a
    # looser `/\bo\b/` match.
    assert_equal "press o for Open in agent", msg.text
  end

  def test_red_status_detail_verb_key_flashes_mode_boundary
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "r", row: row)
    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_equal "press Enter to recover, o to open in agent, Esc or q to close", msg.text
  end

  def test_red_status_detail_unknown_key_returns_noop
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "z", row: row)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_red_status_detail_arrow_keys_scroll_log
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)

    up = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_up, row: row)
    down = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_down, row: row)

    assert_kind_of Hive::Tui::Messages::RedStatusDetailScroll, up
    assert_equal :up, up.direction
    assert_equal 1, up.amount
    assert_kind_of Hive::Tui::Messages::RedStatusDetailScroll, down
    assert_equal :down, down.direction
    assert_equal 1, down.amount
  end

  def test_red_status_detail_page_and_home_end_keys_scroll_log
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)

    pgup = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_pgup, row: row)
    pgdn = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_pgdn, row: row)
    home = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_home, row: row)
    end_key = Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: :key_end, row: row)

    assert_equal [ :up, 10 ], [ pgup.direction, pgup.amount ]
    assert_equal [ :down, 10 ], [ pgdn.direction, pgdn.amount ]
    assert_equal :up, home.direction
    assert_equal Hive::Tui::KeyMap::SCROLL_TO_EDGE, home.amount
    assert_equal :down, end_key.direction
    assert_equal Hive::Tui::KeyMap::SCROLL_TO_EDGE, end_key.amount
  end

  def test_red_status_detail_j_and_k_remain_noops
    row = make_row(action_key: "error", action_label: "Error",
                   marker: "error", attrs: {}, suggested_command: nil)

    assert_same Hive::Tui::Messages::NOOP,
      Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "j", row: row)
    assert_same Hive::Tui::Messages::NOOP,
      Hive::Tui::KeyMap.message_for(mode: :red_status_detail, key: "k", row: row)
  end

  def test_enter_on_needs_input_opens_input_editor_when_command_present
    # Enter on `needs_input` opens the row's input file in $EDITOR —
    # the agent emitted `<!-- WAITING -->` because it wants human
    # edits, so re-dispatching the same verb on Enter would just
    # spawn another agent against the unchanged file. The verb keys
    # remain the explicit way to rerun the agent after editing.
    row = make_row(action_key: "needs_input", action_label: "Needs input",
                   suggested_command: "hive plan some-slug --project alpha --from 3-plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenInputEditor, msg
    assert_same row, msg.row
  end

  def test_enter_on_needs_input_opens_input_editor_without_command
    # Even when the row has no `suggested_command` (e.g., a future
    # state we haven't mapped a verb to yet), Enter still opens the
    # editor — the operator's editing the file, not the verb.
    row = make_row(action_key: "needs_input", action_label: "Needs input",
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenInputEditor, msg
    assert_same row, msg.row
  end

  def test_verb_key_on_needs_input_still_dispatches_suggested_command
    # The verb key path is the explicit "rerun the stage" surface and
    # must stay independent of the Enter-opens-editor change above.
    row = make_row(action_key: "needs_input", action_label: "Needs input",
                   suggested_command: "hive plan some-slug --project alpha --from 3-plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "p", row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal "plan", msg.verb
    assert_equal [ "hive", "plan", "some-slug", "--project", "alpha", "--from", "3-plan" ], msg.argv
  end

  # -------- Sub-mode q/Esc → back --------

  def test_log_tail_q_returns_back
    row = make_row(action_key: "agent_running")
    msg = Hive::Tui::KeyMap.message_for(mode: :log_tail, key: "q", row: row)
    assert_same Hive::Tui::Messages::BACK, msg
  end

  # F2/F16: Esc in filter mode must route to FILTER_CANCELLED (not BACK)
  # so apply_filter_cancelled clears filter_buffer. Routing through BACK
  # left a half-typed query in the buffer for the next `/` open.
  def test_filter_esc_returns_filter_cancelled
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_escape, row: nil)
    assert_same Hive::Tui::Messages::FILTER_CANCELLED, msg
  end

  def test_filter_enter_returns_filter_committed
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_enter, row: nil)
    assert_same Hive::Tui::Messages::FILTER_COMMITTED, msg
  end

  def test_filter_backspace_returns_filter_char_deleted
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_backspace, row: nil)
    assert_same Hive::Tui::Messages::FILTER_CHAR_DELETED, msg
  end

  def test_filter_printable_char_returns_filter_char_appended
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: "a", row: nil)
    assert_kind_of Hive::Tui::Messages::FilterCharAppended, msg
    assert_equal "a", msg.char
  end

  def test_filter_unknown_special_key_is_noop
    # `:key_up` / `:key_down` etc. don't edit the buffer — silently noop
    # so a stray cursor key doesn't move the grid cursor while typing.
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :key_up, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # -------- Unknown key → NOOP --------

  def test_unknown_key_in_grid_returns_noop_singleton
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "Z", row: row)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_unknown_mode_raises
    assert_raises(ArgumentError) do
      Hive::Tui::KeyMap.message_for(mode: :nonexistent, key: "q", row: nil)
    end
  end

  # -------- Total dispatch coverage --------

  def test_message_for_returns_a_message_for_every_supported_fixture
    # ADV-2 audit: probe a representative set of (mode, key, row)
    # combinations and assert each produces a typed Message —
    # never nil, never an exception.
    fixtures = [
      [ :grid, "q",            nil ],
      [ :grid, "?",            nil ],
      [ :grid, "/",            nil ],
      [ :grid, "5",            nil ],
      [ :grid, "j",            make_row(action_key: "ready_to_brainstorm") ],
      [ :grid, "k",            make_row(action_key: "ready_to_brainstorm") ],
      [ :grid, "b",            make_row(action_key: "ready_to_brainstorm") ],
      [ :grid, :key_enter,     make_row(action_key: "agent_running", claude_pid_alive: true, suggested_command: nil) ],
      [ :grid, "p",            make_row(action_key: "agent_running", claude_pid_alive: true, suggested_command: nil) ],
      [ :grid, "p",            make_row(action_key: "archived", suggested_command: nil, action_label: "Archived") ],
      [ :grid, "Z",            make_row(action_key: "ready_to_brainstorm") ],
      [ :log_tail, "q",        make_row(action_key: "agent_running") ],
      [ :log_tail, :key_escape, make_row(action_key: "agent_running") ],
      [ :filter, :key_escape,  nil ],
      [ :idea_preview, "x",    nil ]
    ]

    fixtures.each do |mode, key, row|
      message = Hive::Tui::KeyMap.message_for(mode: mode, key: key, row: row)
      refute_nil message, "(#{mode}, #{key.inspect}) must produce a Message"
      assert_kind_of Object, message
    end
  end

  # Contract: every value in VERB_KEYS is a real workflow verb that
  # `Hive::Workflows::VERBS` defines. Drift would mean pressing the
  # mapped key on a "Ready to X" row dispatches `hive <typo>` and
  # crashes with command-not-found (the same bug class as the U11
  # dogfood-found marker mismatch).
  def test_verb_keys_values_are_workflow_verbs
    require "hive/workflows"

    Hive::Tui::KeyMap::VERB_KEYS.each do |key, verb|
      assert_includes Hive::Workflows::VERBS.keys, verb,
                      "KeyMap maps #{key.inspect} → 'hive #{verb}' but " \
                      "Workflows::VERBS doesn't define '#{verb}'; pressing " \
                      "#{key.inspect} would dispatch a phantom verb."
    end
  end

  def test_grid_capital_x_emits_drop_focused_task_for_right_pane_row
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "X", row: row)

    assert_kind_of Hive::Tui::Messages::DropFocusedTask, msg
    assert_same row, msg.row
  end

  def test_grid_capital_x_requires_right_pane_focus
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "X", row: row, pane_focus: :left)

    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_equal "focus the tasks pane first (Tab or l)", msg.text
  end

  def test_grid_capital_x_with_no_row_flashes_selection_hint
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "X", row: nil)

    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_equal "select a task first; press / to filter or 1-9 to scope", msg.text
  end

  def test_grid_capital_x_refuses_archived_row
    row = make_row(action_key: "archived", stage: "9-done")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "X", row: row)

    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_equal "task is archived; nothing to drop", msg.text
  end

  def test_grid_lowercase_x_is_not_bound_to_drop
    # Lowercase x must NOT trigger the drop — the binding deliberately
    # uses Shift+X to make accidental fat-finger drops unlikely. This
    # also leaves lowercase x available for future bindings.
    row = make_row(action_key: "ready_to_brainstorm")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "x", row: row)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Pin the left-pane + nil-row case: the focus-guard must win over
  # the "select a task first" hint so the operator gets a single,
  # actionable message ("focus the tasks pane first") instead of two
  # conflicting flashes.
  def test_grid_capital_x_left_pane_with_nil_row_flashes_focus_hint
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "X", row: nil, pane_focus: :left)

    assert_kind_of Hive::Tui::Messages::Flash, msg
    assert_equal "focus the tasks pane first (Tab or l)", msg.text
  end
end
