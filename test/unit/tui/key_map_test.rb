require "test_helper"
require "hive/tui/key_map"
require "hive/tui/snapshot"

# `KeyMap.message_for(mode:, key:, row:) → Hive::Tui::Messages::*` is
# the only public dispatch surface after U11; the legacy `dispatch`
# tuple shim was deleted alongside the curses backend. Tests pin the
# Message shapes directly. The discriminative-power audit (ADV-2 from
# the doc review) focuses on branches where the same key produces
# different shapes based on row state: agent_running's three sub-paths,
# stale-lock escape hatch, triage-d's verb caching.
class TuiKeyMapMessageForTest < Minitest::Test
  include HiveTestHelper

  def make_row(action_key:, suggested_command: "hive brainstorm some-slug --from 1-inbox",
               claude_pid_alive: nil, action_label: "Ready to brainstorm",
               slug: "some-slug", project_name: "alpha", stage: "1-inbox",
               folder: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: project_name, stage: stage, slug: slug,
      folder: folder || "/tmp/hive/#{slug}",
      state_file: "/tmp/hive/#{slug}/idea.md",
      marker: "waiting", attrs: {}, mtime: "2026-04-27T12:00:00Z", age_seconds: 1,
      claude_pid: claude_pid_alive ? 1234 : nil, claude_pid_alive: claude_pid_alive,
      action_key: action_key, action_label: action_label,
      suggested_command: suggested_command
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

  def test_triage_d_returns_payload_free_singleton
    # Triage `d` is a payload-free singleton; BubbleModel resolves the
    # develop argv from triage_state so a snapshot poll re-pointing the
    # cursor mid-triage can't dispatch develop on a different task.
    # The argv-shape contract is pinned in TriageState's develop_command
    # test, not here.
    row = make_row(action_key: "review_findings", suggested_command: nil,
                   folder: "/abs/.hive-state/stages/4-execute/some-slug")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "d", row: row)
    assert_same Hive::Tui::Messages::TRIAGE_DEVELOP, msg
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

  def test_grid_l_jumps_pane_focus_to_right
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "l", row: nil)
    assert_kind_of Hive::Tui::Messages::PaneFocusChanged, msg
    assert_equal :right, msg.target
  end

  def test_grid_n_opens_new_idea_prompt
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: "n", row: nil)
    assert_same Hive::Tui::Messages::OPEN_NEW_IDEA_PROMPT, msg
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
    assert_kind_of Hive::Tui::Messages::NewIdeaCharAppended, msg
    assert_equal "r", msg.char
  end

  def test_new_idea_unknown_key_is_noop
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :key_up, row: nil)
    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # Regression: BubbleModel#bubble_key_to_keymap emits `:space` for the
  # SPACE key, but printable_filter_char? returns false for symbols.
  # Without an explicit branch, multi-word titles like "rss feeds"
  # would land as "rssfeeds" in the buffer.
  def test_new_idea_space_symbol_appends_literal_space
    msg = Hive::Tui::KeyMap.message_for(mode: :new_idea, key: :space, row: nil)
    assert_kind_of Hive::Tui::Messages::NewIdeaCharAppended, msg
    assert_equal " ", msg.char
  end

  # Same regression for filter mode — slug filters with spaces like
  # "rss feeds" must work too.
  def test_filter_space_symbol_appends_literal_space
    msg = Hive::Tui::KeyMap.message_for(mode: :filter, key: :space, row: nil)
    assert_kind_of Hive::Tui::Messages::FilterCharAppended, msg
    assert_equal " ", msg.char
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
      suggested_command: "hive plan s --from 2-brainstorm"
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
      suggested_command: "hive plan s --from 2-brainstorm"
    )
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
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

  def test_enter_on_review_findings_returns_open_findings_with_row
    row = make_row(action_key: "review_findings", action_label: "Review findings",
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenFindings, msg
    assert_same row, msg.row
  end

  def test_enter_on_agent_running_returns_open_log_tail_with_row
    row = make_row(action_key: "agent_running", action_label: "Agent running",
                   claude_pid_alive: true, suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenLogTail, msg
    assert_same row, msg.row
  end

  # Enter on an error-state row opens the agent log so the user can see
  # WHY the agent failed without leaving the TUI. Replaces the earlier
  # "inspect via $EDITOR" flash, which was stale after the `$EDITOR`
  # integration was removed.
  def test_enter_on_error_returns_open_log_tail_with_row
    row = make_row(action_key: "error", action_label: "Error",
                   suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::OpenLogTail, msg,
      "Enter on error rows must open log tail (the user wants to see why it failed), " \
      "not flash a stale `$EDITOR` hint"
    assert_same row, msg.row
  end

  def test_enter_on_needs_input_dispatches_when_command_present
    row = make_row(action_key: "needs_input", action_label: "Needs input",
                   suggested_command: "hive plan some-slug --project alpha --from 3-plan")
    msg = Hive::Tui::KeyMap.message_for(mode: :grid, key: :key_enter, row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal "plan", msg.verb
  end

  # -------- Triage rebindings --------

  def test_triage_a_returns_bulk_accept_singleton
    # Bulk a/r are payload-free singletons; BubbleModel routes them
    # against triage_state, not the live row's slug.
    row = make_row(action_key: "review_findings", slug: "auth-fix-260101-a1b2")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "a", row: row)
    assert_same Hive::Tui::Messages::BULK_ACCEPT, msg
  end

  def test_triage_r_returns_bulk_reject_singleton
    row = make_row(action_key: "review_findings", slug: "auth-fix-260101-a1b2")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "r", row: row)
    assert_same Hive::Tui::Messages::BULK_REJECT, msg
  end

  def test_triage_space_returns_toggle_finding_with_row
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: " ", row: row)
    assert_kind_of Hive::Tui::Messages::ToggleFinding, msg
    assert_same row, msg.row
  end

  def test_triage_esc_returns_back_singleton
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: :key_escape, row: row)
    assert_same Hive::Tui::Messages::BACK, msg
  end

  # Triage-mode cursor must NOT emit grid-mode CURSOR_DOWN/UP — those
  # singletons drive `model.cursor` (grid coord) and would not move the
  # finding cursor that lives on `triage_state`. F1 fix from
  # /ce-code-review walk-through.
  def test_triage_j_returns_triage_cursor_down_singleton
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "j", row: row)
    assert_same Hive::Tui::Messages::TRIAGE_CURSOR_DOWN, msg
  end

  def test_triage_key_down_returns_triage_cursor_down_singleton
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: :key_down, row: row)
    assert_same Hive::Tui::Messages::TRIAGE_CURSOR_DOWN, msg
  end

  def test_triage_k_returns_triage_cursor_up_singleton
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "k", row: row)
    assert_same Hive::Tui::Messages::TRIAGE_CURSOR_UP, msg
  end

  def test_triage_key_up_returns_triage_cursor_up_singleton
    row = make_row(action_key: "review_findings")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: :key_up, row: row)
    assert_same Hive::Tui::Messages::TRIAGE_CURSOR_UP, msg
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
      [ :grid, :key_enter,     make_row(action_key: "review_findings", suggested_command: nil) ],
      [ :grid, :key_enter,     make_row(action_key: "agent_running", claude_pid_alive: true, suggested_command: nil) ],
      [ :grid, "p",            make_row(action_key: "agent_running", claude_pid_alive: true, suggested_command: nil) ],
      [ :grid, "p",            make_row(action_key: "archived", suggested_command: nil, action_label: "Archived") ],
      [ :grid, "Z",            make_row(action_key: "ready_to_brainstorm") ],
      [ :triage, " ",          make_row(action_key: "review_findings") ],
      [ :triage, "d",          make_row(action_key: "review_findings") ],
      [ :triage, "a",          make_row(action_key: "review_findings") ],
      [ :triage, "r",          make_row(action_key: "review_findings") ],
      [ :triage, :key_escape,  make_row(action_key: "review_findings") ],
      [ :triage, :key_down,    make_row(action_key: "review_findings") ],
      [ :log_tail, "q",        make_row(action_key: "agent_running") ],
      [ :log_tail, :key_escape, make_row(action_key: "agent_running") ],
      [ :filter, :key_escape,  nil ]
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
end
