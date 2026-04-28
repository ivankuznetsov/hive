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
               slug: "some-slug", project_name: "alpha", stage: "1-inbox")
    Hive::Tui::Snapshot::Row.new(
      project_name: project_name, stage: stage, slug: slug,
      folder: "/tmp/hive/#{slug}", state_file: "/tmp/hive/#{slug}/idea.md",
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

  def test_triage_d_caches_develop_verb
    # Triage `d` synthesizes the argv directly (not from
    # suggested_command); verb must still cache as "develop".
    row = make_row(action_key: "review_findings", suggested_command: nil)
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "d", row: row)
    assert_kind_of Hive::Tui::Messages::DispatchCommand, msg
    assert_equal "develop", msg.verb
    assert_equal [ "hive", "develop", "some-slug", "--from", "4-execute" ], msg.argv
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

  def test_triage_a_returns_bulk_accept_with_slug
    row = make_row(action_key: "review_findings", slug: "auth-fix-260101-a1b2")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "a", row: row)
    assert_kind_of Hive::Tui::Messages::BulkAccept, msg
    assert_equal "auth-fix-260101-a1b2", msg.slug
  end

  def test_triage_r_returns_bulk_reject_with_slug
    row = make_row(action_key: "review_findings", slug: "auth-fix-260101-a1b2")
    msg = Hive::Tui::KeyMap.message_for(mode: :triage, key: "r", row: row)
    assert_kind_of Hive::Tui::Messages::BulkReject, msg
    assert_equal "auth-fix-260101-a1b2", msg.slug
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
