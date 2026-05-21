require "test_helper"
require "hive/tui/bubble_model"

# Pin the BubbleModel adapter's translation/dispatch contract:
# framework messages → Hive Messages, KeyMessage → KeyMap.message_for,
# DispatchCommand → takeover_command, sub-mode entries set state.
# Excludes the side-effect handlers that need real subprocesses
# (toggle_finding/bulk_*) — those are exercised by integration tests.
class HiveTuiBubbleModelTest < Minitest::Test
  include HiveTestHelper

  def setup
    @messages = []
    @dispatch = ->(m) { @messages << m }
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch
    )
  end

  def key_message(key_type, runes: [])
    Bubbletea::KeyMessage.new(key_type: key_type, runes: runes)
  end

  def make_task_row(action_key: "needs_input", slug: "some-slug", stage: "2-brainstorm",
                    state_file: "/tmp/hive/some-slug/brainstorm.md",
                    suggested_command: "hive brainstorm some-slug --from 2-brainstorm",
                    marker: "waiting", attrs: {}, folder: nil,
                    action_label: "Needs your input", next_action: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo", stage: stage, slug: slug, folder: folder || "/tmp/hive/#{slug}",
      state_file: state_file, marker: marker, attrs: attrs, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: action_key, action_label: action_label,
      suggested_command: suggested_command, next_action: next_action,
      diagnostic: nil
    )
  end

  def with_editor_env(visual:, editor:)
    old_visual = ENV["VISUAL"]
    old_editor = ENV["EDITOR"]
    visual.nil? ? ENV.delete("VISUAL") : ENV["VISUAL"] = visual
    editor.nil? ? ENV.delete("EDITOR") : ENV["EDITOR"] = editor
    yield
  ensure
    old_visual.nil? ? ENV.delete("VISUAL") : ENV["VISUAL"] = old_visual
    old_editor.nil? ? ENV.delete("EDITOR") : ENV["EDITOR"] = old_editor
  end

  def write_idea_md(dir, original_text:)
    indented_original = original_text.lines.map { |line| "  #{line.chomp}" }
    body = [
      "---",
      "slug: some-slug",
      "created_at: 2026-05-20T00:00:00Z",
      "original_text: |",
      *indented_original,
      "---",
      "",
      "# some-slug",
      "",
      original_text,
      "",
      "<!-- WAITING -->",
      ""
    ].join("\n")
    path = File.join(dir, "idea.md")
    File.write(path, body)
    path
  end

  # ---- Construction / init ----

  def test_init_returns_self_and_yield_tick
    new_model, cmd = @model.init
    assert_same @model, new_model
    # init seeds a recurring YieldTick so background threads (StateSource
    # snapshot polling) get GVL time between bubbletea's input polls.
    assert_kind_of Bubbletea::TickCommand, cmd,
      "init must seed the yield tick so the GVL-yield cycle starts"
  end

  def test_yield_tick_message_reschedules_a_fresh_tick
    # Once the yield-tick cycle is running, every YieldTick observation
    # must produce a fresh TickCommand or the cycle stalls.
    _, cmd = @model.update(Hive::Tui::Messages::YIELD_TICK)
    assert_kind_of Bubbletea::TickCommand, cmd,
      "update on YieldTick must return a fresh tick to keep the cycle going"
  end

  def test_yield_tick_callback_yields_gvl_and_returns_yield_tick_message
    # The callback is the actual GVL-yield mechanism — without
    # `Thread.pass` inside it, the StateSource polling thread starves
    # under bubbletea's tight input-poll loop. This test invokes the
    # callback directly so a regression removing `Thread.pass` (or
    # changing the return value) trips a meaningful failure.
    cmd = @model.send(:yield_tick_cmd)
    callback = cmd.instance_variable_get(:@callback)
    refute_nil callback, "TickCommand must carry an invokable callback"
    result = callback.call
    assert_equal Hive::Tui::Messages::YIELD_TICK, result,
      "callback must return YIELD_TICK so update() reschedules the cycle"
  end

  # ---- WindowSizeMessage translation ----

  def test_window_size_message_translates_to_window_sized
    msg = Bubbletea::WindowSizeMessage.new(width: 120, height: 40)
    @model.update(msg)
    assert_equal 120, @model.hive_model.cols
    assert_equal 40, @model.hive_model.rows
  end

  # ---- KeyMessage → KeyMap.message_for translation ----

  def test_q_keystroke_dispatches_terminate
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "q".ord ])
    _, cmd = @model.update(km)
    # Bubbletea.quit is a Bubbletea::QuitCommand
    assert_kind_of Bubbletea::QuitCommand, cmd
  end

  def test_question_mark_opens_help
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "?".ord ])
    @model.update(km)
    assert_equal :help, @model.hive_model.mode
  end

  def test_slash_opens_filter_prompt
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "/".ord ])
    @model.update(km)
    assert_equal :filter, @model.hive_model.mode
  end

  # F2: full filter happy path through KeyMessage → KeyMap → Update.
  # Open filter, type chars, commit; assert filter committed and mode
  # back to :grid. Pins the regression we found in the /ce-code-review
  # walk-through where every filter keystroke silently NOOPed.
  def test_filter_mode_typing_and_enter_commits_filter
    @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ "/".ord ]))
    "auth".each_char do |c|
      @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ c.ord ]))
    end
    assert_equal "auth", @model.hive_model.filter_buffer

    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER))
    assert_equal "auth", @model.hive_model.filter
    assert_equal :grid, @model.hive_model.mode
    assert_equal "", @model.hive_model.filter_buffer
  end

  def test_filter_mode_backspace_shrinks_buffer
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "auth"),
      dispatch: @dispatch
    )
    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_BACKSPACE))
    assert_equal "aut", @model.hive_model.filter_buffer
  end

  # F16: Esc-in-filter must clear filter_buffer (was leaking the
  # half-typed query into the next `/` open because the message
  # routed through BACK instead of FILTER_CANCELLED).
  def test_filter_mode_escape_clears_buffer_and_returns_to_grid
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "wip", filter: "auth"),
      dispatch: @dispatch
    )
    @model.update(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ESC))
    assert_equal :grid, @model.hive_model.mode
    assert_equal "", @model.hive_model.filter_buffer
    # Esc preserves any prior committed filter — only clears the
    # in-progress buffer.
    assert_equal "auth", @model.hive_model.filter
  end

  def test_digit_keystroke_sets_project_scope
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "2".ord ])
    @model.update(km)
    assert_equal 2, @model.hive_model.scope
  end

  def test_unknown_keystroke_is_noop
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "x".ord ])
    snapshot_before = @model.hive_model
    _, cmd = @model.update(km)
    assert_nil cmd
    assert_equal snapshot_before.mode, @model.hive_model.mode,
      "unknown keystrokes must not flip mode"
  end

  def test_left_key_message_focuses_projects_pane_in_grid_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, pane_focus: :right, cols: 100),
      dispatch: @dispatch
    )

    @model.update(key_message(Bubbletea::KeyMessage::KEY_LEFT))

    assert_equal :left, @model.hive_model.pane_focus
  end

  def test_right_key_message_focuses_tasks_pane_in_grid_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, pane_focus: :left, cols: 100),
      dispatch: @dispatch
    )

    @model.update(key_message(Bubbletea::KeyMessage::KEY_RIGHT))

    assert_equal :right, @model.hive_model.pane_focus
  end

  def test_bubble_key_to_keymap_translates_new_idea_editing_keys
    {
      Bubbletea::KeyMessage::KEY_LEFT => :key_left,
      Bubbletea::KeyMessage::KEY_RIGHT => :key_right,
      Bubbletea::KeyMessage::KEY_HOME => :key_home,
      Bubbletea::KeyMessage::KEY_END => :key_end,
      Bubbletea::KeyMessage::KEY_DELETE => :key_delete,
      Bubbletea::KeyMessage::KEY_CTRL_A => :key_ctrl_a,
      Bubbletea::KeyMessage::KEY_CTRL_E => :key_ctrl_e,
      Bubbletea::KeyMessage::KEY_CTRL_V => :key_ctrl_v
    }.each do |key_type, expected|
      assert_equal expected, @model.send(:bubble_key_to_keymap, key_message(key_type))
    end
  end

  def test_translate_ctrl_v_keymessage_requests_new_idea_paste_probe
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )

    msg = @model.send(:translate_key, key_message(Bubbletea::KeyMessage::KEY_CTRL_V))

    assert_kind_of Hive::Tui::Messages::NewIdeaPasteRequested, msg
    assert_equal "", msg.raw_text
  end

  def test_translate_ctrl_v_keymessage_is_noop_outside_new_idea
    %i[grid filter].each do |mode|
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: mode),
        dispatch: @dispatch
      )

      msg = @model.send(:translate_key, key_message(Bubbletea::KeyMessage::KEY_CTRL_V))

      assert_same Hive::Tui::Messages::NOOP, msg
    end
  end

  def test_raw_text_input_in_new_idea_mode_inserts_at_cursor
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, new_idea_buffer: "ac", new_idea_cursor: 1
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::RawTextInput.new(text: "b", paste: false))

    assert_equal "abc", @model.hive_model.new_idea_buffer
    assert_equal 2, @model.hive_model.new_idea_cursor
  end

  def test_raw_text_input_in_filter_mode_appends_to_filter_buffer
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "au"),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::RawTextInput.new(text: "th", paste: true))

    assert_equal "auth", @model.hive_model.filter_buffer
  end

  def test_raw_text_input_in_grid_mode_is_noop
    before = @model.hive_model

    @model.update(Hive::Tui::Messages::RawTextInput.new(text: "paste", paste: true))

    assert_equal before, @model.hive_model
  end

  # ---- View dispatch by mode ----

  def test_view_renders_grid_in_grid_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "hive tui"
  end

  def test_view_renders_help_overlay_in_help_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "hive tui — keybindings"
  end

  def test_view_composes_filter_prompt_onto_grid_in_filter_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: "auth"),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "/auth"
  end

  def test_view_composes_idea_preview_onto_grid_in_idea_preview_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :idea_preview,
        idea_preview_slug: "some-slug",
        idea_preview_text: "original idea"
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "Idea for some-slug:"
    assert_includes out, "original idea"
  end

  # Regression: paste-truncated / paste-timeout / overflow flashes
  # raised inside :filter mode were invisible because compose_filter_view
  # passed the filter prompt as the footer, replacing default_footer
  # (the only place flashes render).
  def test_view_renders_active_flash_above_filter_prompt
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :filter, filter_buffer: "auth",
        flash: "paste truncated", flash_set_at: Time.now
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "/auth", "filter prompt must still render"
    assert_includes out, "paste truncated", "active flash must surface above the prompt"
    assert out.index("paste truncated") < out.index("/auth"),
           "flash row must precede the prompt strip so it is visible"
  end

  # Same regression for :new_idea mode — the partial-fit truncation
  # flash, the title-too-long flash, and the decoder overflow Flash all
  # land here.
  def test_view_renders_active_flash_above_new_idea_prompt
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, new_idea_buffer: "rss feeds", new_idea_cursor: 9,
        flash: "title truncated to 4096 chars", flash_set_at: Time.now
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "rss feeds", "new-idea prompt must still render the buffer"
    assert_includes out, "title truncated", "active flash must surface above the prompt"
    assert out.index("title truncated") < out.index("rss feeds"),
           "flash row must precede the prompt strip so it is visible"
  end

  # Negative: when no active flash, the prompt is the only footer line —
  # no blank flash row, no "nil" rendering.
  def test_view_omits_flash_row_when_no_active_flash_in_new_idea_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, new_idea_buffer: "draft", new_idea_cursor: 5,
        flash: nil, flash_set_at: nil
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "draft"
    refute_match(/^\s*$/, out.lines.last(2).first.to_s,
                 "no spurious blank flash row when flash is nil")
  end

  # ---- v2 two-pane composition ----

  def test_grid_mode_renders_both_panes_at_full_width
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "fix-cache-x", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 100),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "Projects",      "left pane (Projects header) must render at >=70 cols"
    assert_includes out, "★ All projects"
    assert_includes out, "fix-cache-x",   "right pane task row must render"
    assert_includes out, "Tasks ·",       "tasks pane title must render"
    assert_includes out, "[Tab] switch",  "default footer hints must appear"
    assert_includes out, "[Enter] action", "Enter footer hint must describe contextual behavior"
    refute_includes out, "[Enter] open",   "Enter is not only an open action"
  end

  def test_default_footer_hint_omits_o_at_70_col_budget
    # Plan R6: `[o] open` is included in the footer only if it fits
    # the 70-col budget without wrapping or pushing primary actions
    # onto a second line. At 70 cols the current hint string is
    # already ~69 chars; adding ten more (separator + "[o] open")
    # would exceed the budget. We rely on the `?` overlay for
    # discoverability instead. This test pins that decision so a
    # future contributor doesn't silently re-add the hint and break
    # 70-col rendering.
    hint = @model.send(:footer_hint)
    assert_equal "[Tab] switch  [Enter] action  [n] new  [/] filter  [?] help  [q] quit",
                 hint,
                 "footer hint must remain the pre-`o` literal; `o` is documented in `?` only"
    refute_includes hint, "[o] open",
                    "70-col budget can't absorb `[o] open` alongside primary hints"
    # Width guard: pin the actual character count so a future contributor
    # who adds a hint and (correctly) bumps the literal above also has to
    # acknowledge they're spending bytes against the 70-col budget. If
    # this assertion fires alongside an updated literal, the contributor
    # MUST verify default_footer truncation behavior at cols == 70.
    assert hint.length <= 70,
           "footer hint must fit the 70-col budget without truncation; got #{hint.length} chars"
  end

  def test_grid_mode_collapses_to_single_pane_below_min_cols
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "narrow-task", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 60),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "narrow-task", "tasks pane must still render below the threshold"
    refute_includes out, "Projects\n", "Projects pane title must NOT appear when collapsed"
    refute_includes out, "★ All projects\n", "left pane (with ★ prefix) must not render at narrow widths"
  end

  def test_pane_widths_clamps_left_to_18_28_range
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(cols: 200),
      dispatch: @dispatch
    )
    left, right = @model.send(:pane_widths, 200)
    assert_operator left, :>=, 18
    assert_operator left, :<=, 28
    # Right pane reserves a 1-cell margin so the rightmost border
    # glyph never lands in the terminal's last column (some terminals
    # don't reliably render that cell).
    assert_equal 199, left + right
  end

  def test_pane_widths_floors_quarter_with_right_margin
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(cols: 100),
      dispatch: @dispatch
    )
    left, right = @model.send(:pane_widths, 100)
    assert_equal 25, left, "100 * 0.25 = 25; within [18, 28] so no clamp"
    assert_equal 74, right, "right pane reserves 1-cell margin (cols - left - 1)"
  end

  def test_two_pane_min_cols_constant_is_70
    assert_equal 70, Hive::Tui::BubbleModel::TWO_PANE_MIN_COLS
  end

  def test_grid_mode_renders_at_exactly_70_cols
    # Boundary: cols == 70 must use two-pane layout (inclusive on the
    # upper side of the fallback test).
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 70),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "Projects", "70 cols is the inclusive boundary — two-pane must render"
  end

  # Regression for v2 P0: bubble_key_to_keymap previously dropped TAB
  # and SHIFT_TAB on the floor (returned NOOP), making the headline
  # pane-focus toggle silently dead. KeyMap unit tests bypass the
  # translator by passing :key_tab directly, so this lives here at the
  # BubbleModel layer where the bug actually surfaced.
  def test_bubble_key_to_keymap_translates_tab_to_key_tab
    fake_km = Object.new
    fake_km.define_singleton_method(:enter?) { false }
    fake_km.define_singleton_method(:esc?) { false }
    fake_km.define_singleton_method(:up?) { false }
    fake_km.define_singleton_method(:down?) { false }
    fake_km.define_singleton_method(:backspace?) { false }
    fake_km.define_singleton_method(:space?) { false }
    fake_km.define_singleton_method(:tab?) { true }
    fake_km.define_singleton_method(:char) { "" }
    fake_km.define_singleton_method(:key_type) { 0 }
    assert_equal :key_tab, @model.send(:bubble_key_to_keymap, fake_km)
  end

  def test_bubble_key_to_keymap_translates_shift_tab_to_key_backtab
    fake_km = Object.new
    fake_km.define_singleton_method(:enter?) { false }
    fake_km.define_singleton_method(:esc?) { false }
    fake_km.define_singleton_method(:up?) { false }
    fake_km.define_singleton_method(:down?) { false }
    fake_km.define_singleton_method(:backspace?) { false }
    fake_km.define_singleton_method(:space?) { false }
    fake_km.define_singleton_method(:tab?) { false }
    fake_km.define_singleton_method(:char) { "" }
    fake_km.define_singleton_method(:key_type) { Bubbletea::KeyMessage::KEY_SHIFT_TAB }
    assert_equal :key_backtab, @model.send(:bubble_key_to_keymap, fake_km)
  end

  def test_grid_mode_falls_back_at_cols_69_exclusive_boundary
    # The exclusive lower boundary of the two-pane layout. cols = 69
    # must collapse to single-pane (TWO_PANE_MIN_COLS = 70). Without
    # this test only cols=60 (well below) and cols=70 (inclusive) are
    # pinned; a refactor that changes < to <= would slip through.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [
        { "name" => "hive", "tasks" => [
          { "slug" => "boundary-task", "stage" => "2-brainstorm", "action" => "ready_to_plan",
            "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
        ] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 69),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "boundary-task", "tasks pane must still render at the fallback boundary"
    refute_includes out, "Projects\n", "Projects pane title must NOT appear at cols < 70"
  end

  # Regression: deleting v1 Views::Grid silently dropped the
  # stalled-poll banner — transient StateSource errors became
  # invisible. The v2 composer must surface model.last_error.
  def test_grid_mode_renders_stalled_banner_when_last_error_set
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    err = StandardError.new("connection refused")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :grid, snapshot: snap, cols: 100, last_error: err
      ),
      dispatch: @dispatch
    )
    out = @model.view
    assert_includes out, "stalled",
                    "stalled banner must appear when last_error is set"
    assert_includes out, "connection refused",
                    "stalled banner must surface the error message for diagnosis"
  end

  def test_grid_mode_handles_nil_snapshot
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: nil, cols: 100),
      dispatch: @dispatch
    )
    out = @model.view
    refute_nil out, "nil snapshot must not crash compose_two_pane_view"
    assert out.is_a?(String)
  end

  # ---- v2 new-idea submission ----

  # Stub Hive::Tui::Subprocess.run_quiet! for the duration of a block.
  # Saves/restores the original via singleton-method swap so multiple
  # tests don't leak across each other when run in random order.
  def with_run_quiet_stub(stub_proc)
    sentinel = Hive::Tui::Subprocess.method(:run_quiet!)
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!, &stub_proc)
    yield
  ensure
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!, sentinel) if sentinel
  end

  def with_dispatch_background_stub(stub_proc)
    sentinel = Hive::Tui::Subprocess.method(:dispatch_background)
    Hive::Tui::Subprocess.define_singleton_method(:dispatch_background, &stub_proc)
    yield
  ensure
    Hive::Tui::Subprocess.define_singleton_method(:dispatch_background, sentinel) if sentinel
  end

  def test_refresh_red_status_diagnosis_dispatches_status_diagnose_and_dedups
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      marker: "error",
      attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row, marker_signature: "error")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
      dispatch: @dispatch
    )

    calls = []
    with_dispatch_background_stub(->(argv, **_kwargs) { calls << argv; nil }) do
      @model.update(Hive::Tui::Messages::RefreshRedStatusDiagnosis.new(row: row))
      @model.update(Hive::Tui::Messages::RefreshRedStatusDiagnosis.new(row: row))
    end

    # --stage disambiguates when the same slug exists in multiple stages
    # of the same project. TaskResolver raises AmbiguousSlug otherwise,
    # which the operator sees as "diagnosis failed to start" — silently
    # losing the refresh signal.
    #
    # --force is appended on the R-press path so the CLI's
    # marker_signature idempotency short-circuit (silent cache reuse)
    # does NOT fire. Without --force, R-press would flash "refreshed"
    # while no new agent ran (PR #84 review row 8).
    expected = [ "hive", "status", "--diagnose", row.slug,
                 "--project", row.project_name, "--stage", row.stage,
                 "--write", "--force" ]
    assert_equal [ expected ], calls
    assert @model.hive_model.red_status_detail_state.refreshing
    assert_match(/already in progress/, @model.hive_model.flash)
  end

  def test_refresh_red_status_diagnosis_short_circuits_when_autofix_inflight
    # If a recover_review autofix is already running for the row, R-press
    # must refuse rather than spawn a parallel diagnose. The autofix path
    # holds the per-task `hive run` lock; a parallel diagnose would fail
    # at the flock or describe pre-autofix state. See PR #84 review row 13.
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      marker: "review_error",
      attrs: { "phase" => "fix", "pass" => "1" },
      suggested_command: nil
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch
    )
    # Simulate an in-flight autofix by claiming the recovery slot.
    inflight = @model.instance_variable_get(:@review_recovery_inflight)
    inflight.add(row.folder)

    calls = []
    with_dispatch_background_stub(->(argv, **_kwargs) { calls << argv; nil }) do
      @model.update(Hive::Tui::Messages::RefreshRedStatusDiagnosis.new(row: row))
    end

    assert_empty calls,
                 "diagnose must not dispatch when autofix is already running"
    assert_match(/autofix already running/i, @model.hive_model.flash)
  end

  def test_refresh_red_status_diagnosis_short_circuits_when_error_autofix_inflight
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      marker: "error",
      attrs: { "exit_code" => "70" },
      suggested_command: nil
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch
    )
    inflight = @model.instance_variable_get(:@error_recovery_inflight)
    inflight.add(row.folder)

    calls = []
    with_dispatch_background_stub(->(argv, **_kwargs) { calls << argv; nil }) do
      @model.update(Hive::Tui::Messages::RefreshRedStatusDiagnosis.new(row: row))
    end

    assert_empty calls,
                 "diagnose must not dispatch when error autofix is already running"
    assert_match(/autofix already running/i, @model.hive_model.flash)
  end

  def test_refresh_red_status_diagnosis_short_circuits_on_agent_running_row
    # action_key=='agent_running' means the row is currently being
    # processed by a workflow agent (claude/codex). Same refuse-then-flash
    # contract as the autofix-inflight branch.
    row = make_task_row(
      action_key: "agent_running",
      action_label: "Agent running",
      marker: "agent_working",
      attrs: { "pid" => "12345" },
      suggested_command: nil
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch
    )
    calls = []
    with_dispatch_background_stub(->(argv, **_kwargs) { calls << argv; nil }) do
      @model.update(Hive::Tui::Messages::RefreshRedStatusDiagnosis.new(row: row))
    end

    assert_empty calls,
                 "diagnose must not dispatch when action_key is agent_running"
    assert_match(/autofix already running/i, @model.hive_model.flash)
  end

  def test_diagnose_subprocess_exit_success_flashes_and_evicts_inflight
    # success case: exit_code zero → "refreshed" flash, slot evicted so
    # a subsequent R-press can run. See PR #84 review row 14.
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      marker: "error",
      attrs: {},
      suggested_command: nil
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row, marker_signature: "sig", refreshing: true)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
      dispatch: @dispatch
    )
    inflight = @model.instance_variable_get(:@diagnosis_inflight)
    inflight.add(row.folder)

    @model.update(
      Hive::Tui::Messages::SubprocessExited.new(verb: "status", exit_code: 0, folder: row.folder)
    )

    refute_includes inflight, row.folder,
                    "successful diagnose exit must evict the inflight slot"
    assert_match(/refreshed/, @model.hive_model.flash)
    refute @model.hive_model.red_status_detail_state.refreshing,
           "refreshing flag must clear on subprocess exit"
  end

  def test_diagnose_subprocess_exit_failure_flashes_and_evicts_inflight
    # failure case: non-zero exit → operator-actionable failure flash
    # AND the slot is evicted so a retry is possible.
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      marker: "error",
      attrs: {},
      suggested_command: nil
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row, marker_signature: "sig", refreshing: true)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
      dispatch: @dispatch
    )
    inflight = @model.instance_variable_get(:@diagnosis_inflight)
    inflight.add(row.folder)

    @model.update(
      Hive::Tui::Messages::SubprocessExited.new(verb: "status", exit_code: 1, folder: row.folder)
    )

    refute_includes inflight, row.folder,
                    "failed diagnose exit must STILL evict the inflight slot (retry must be possible)"
    refute @model.hive_model.red_status_detail_state.refreshing,
           "refreshing flag must clear on subprocess exit (even on failure)"
    refute_nil @model.hive_model.flash
  end

  def test_open_manual_fix_opens_task_worktree_without_changing_marker
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "manual-fix-260516-aaaa"
      folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      worktree = File.join(project_root, "worktrees", slug)
      FileUtils.mkdir_p(folder)
      FileUtils.mkdir_p(worktree)
      marker_path = File.join(folder, "task.md")
      marker_body = "<!-- REVIEW_ERROR phase=fix pass=1 -->\n"
      File.write(marker_path, marker_body)
      File.write(File.join(folder, "worktree.yml"), { "path" => worktree }.to_yaml)
      row = make_task_row(
        action_key: "error",
        action_label: "Error",
        stage: "6-review",
        slug: slug,
        folder: folder,
        state_file: marker_path,
        marker: "error",
        attrs: { "reason" => "exit_code", "exit_code" => "1" },
        suggested_command: nil
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }

      _model, cmd = @model.update(Hive::Tui::Messages::OpenManualFix.new(row: row))

      refute_nil cmd
      assert_match(/opening worktree/, @model.hive_model.flash)
      assert_equal marker_body, File.read(marker_path)
    end
  end

  def with_clipboard_probe_stub(stub_proc)
    sentinel = @model.instance_variable_get(:@clipboard_probe)
    @model.instance_variable_set(:@clipboard_probe, stub_proc)
    yield
  ensure
    @model.instance_variable_set(:@clipboard_probe, sentinel) if @model
  end

  def with_composer_ensure_dir_stub(stub_proc)
    sentinel = Hive::Tui::ComposerStaging.method(:ensure_dir!)
    Hive::Tui::ComposerStaging.define_singleton_method(:ensure_dir!, &stub_proc)
    yield
  ensure
    Hive::Tui::ComposerStaging.define_singleton_method(:ensure_dir!, sentinel) if sentinel
  end

  def clipboard_none
    Hive::Tui::Clipboard::NONE
  end

  def clipboard_image_bytes(bytes: "png".b, ext: "png")
    Hive::Tui::Clipboard::ProbeResult.image_bytes(bytes: bytes, ext: ext)
  end

  def clipboard_image_file(path, ext: File.extname(path).delete_prefix("."))
    Hive::Tui::Clipboard::ProbeResult.image_file(path: path, ext: ext)
  end

  def test_new_idea_submission_dispatches_hive_new_with_resolved_project
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0,
        new_idea_project_name: "hive", new_idea_buffer: "rss feeds"
      ),
      dispatch: @dispatch
    )
    captured_argv = nil
    with_run_quiet_stub(->(argv) { captured_argv = argv; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal [ "hive", "new", "hive", "rss feeds" ], captured_argv,
                 "submission must shell out to `hive new <project> <title>` " \
                 "(argv[0] is the executable; Open3.popen3 execs literally)"
    assert_equal :grid, @model.hive_model.mode, "successful submit must return to :grid"
    assert_equal "", @model.hive_model.new_idea_buffer
  end

  def test_new_idea_empty_paste_with_clipboard_image_stages_file_and_inserts_placeholder
    bytes = Hive::Tui::Clipboard::PNG_SIGNATURE + "payload".b
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    probe_result = clipboard_image_bytes(bytes: bytes)
    assert_equal :new_idea, @model.hive_model.mode
    captured_pasted_text = nil

    with_clipboard_probe_stub(->(pasted_text:, **_kwargs) {
      captured_pasted_text = pasted_text
      probe_result
    }) do
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
    end

    assert_equal "", captured_pasted_text
    assert_equal "[image1]", @model.hive_model.new_idea_buffer
    assert_equal 1, @model.hive_model.new_idea_attachments.size
    attachment = @model.hive_model.new_idea_attachments.first
    assert_equal "image1", attachment.label
    assert_equal bytes, File.binread(attachment.staging_path)
    assert File.directory?(@model.hive_model.new_idea_staging_dir)
  ensure
    Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
  end

  # R16: pasting the same image bytes twice in a row must produce
  # two distinct staged files (no dedup). The composer is intentionally
  # additive — a user pasting the same screenshot twice has signalled
  # they want both placeholders in the body, and silently collapsing
  # them would lose buffer-cursor positioning the user typed around.
  def test_new_idea_same_image_bytes_pasted_twice_yields_two_distinct_files
    bytes = Hive::Tui::Clipboard::PNG_SIGNATURE + "payload".b
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    probe_result = clipboard_image_bytes(bytes: bytes)

    with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
    end

    attachments = @model.hive_model.new_idea_attachments
    assert_equal 2, attachments.size, "same bytes pasted twice must NOT dedup"
    assert_equal %w[image1 image2], attachments.map(&:label)
    paths = attachments.map(&:staging_path)
    assert_equal paths.uniq, paths, "two paste events must yield two distinct staging paths"
    paths.each { |p| assert_equal bytes, File.binread(p) }
  ensure
    Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
  end

  def test_new_idea_paste_with_image_file_copies_to_staging
    with_tmp_dir do |dir|
      src = File.join(dir, "shot.png")
      File.binwrite(src, "fixture-image".b)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
        dispatch: @dispatch
      )
      probe_result = clipboard_image_file(src, ext: "png")

      with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
        @model.update(Hive::Tui::Messages::RawTextInput.new(text: src, paste: true))
      end

      attachment = @model.hive_model.new_idea_attachments.first
      assert_equal "[image1]", @model.hive_model.new_idea_buffer
      assert_equal "fixture-image", File.binread(attachment.staging_path)
      refute_equal src, attachment.staging_path
    ensure
      Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
    end
  end

  # R4: drag-drop from a file manager often delivers the path
  # wrapped in double quotes and trailing newline (`"<path>"\n`). The
  # clipboard-layer probe strips both via `normalized_path`; the
  # BubbleModel layer must thread the raw payload through without
  # mutation so a future `translate_raw_text_input` regression that
  # trims the payload before delivery would fail here.
  def test_new_idea_paste_with_quoted_path_threads_raw_text_to_clipboard_probe
    with_tmp_dir do |dir|
      src = File.join(dir, "shot.png")
      File.binwrite(src, "fixture-image".b)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
        dispatch: @dispatch
      )
      probe_result = clipboard_image_file(src, ext: "png")
      captured_pasted_text = nil

      with_clipboard_probe_stub(->(pasted_text:, **_kwargs) {
        captured_pasted_text = pasted_text
        probe_result
      }) do
        @model.update(Hive::Tui::Messages::RawTextInput.new(text: "\"#{src}\"\n", paste: true))
      end

      assert_equal "\"#{src}\"\n", captured_pasted_text,
        "quoted + trailing-newline payload must reach Clipboard.probe verbatim"
      assert_equal "[image1]", @model.hive_model.new_idea_buffer
    ensure
      Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
    end
  end

  def test_new_idea_paste_without_image_falls_back_to_text
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    probe_result = clipboard_none

    with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "some words", paste: true))
    end

    assert_equal "some words", @model.hive_model.new_idea_buffer
    assert_equal [], @model.hive_model.new_idea_attachments
  end

  def test_new_idea_image_paste_at_buffer_cap_is_refused_without_orphan_file
    bytes = Hive::Tui::Clipboard::PNG_SIGNATURE + "payload".b
    existing = "x" * Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        new_idea_buffer: existing,
        new_idea_cursor: existing.length
      ),
      dispatch: @dispatch
    )
    probe_result = clipboard_image_bytes(bytes: bytes)
    write_called = false

    with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
      orig = Hive::Tui::ComposerStaging.method(:write_bytes!)
      Hive::Tui::ComposerStaging.singleton_class.define_method(:write_bytes!) do |*args|
        write_called = true
        orig.call(*args)
      end
      begin
        @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
      ensure
        Hive::Tui::ComposerStaging.singleton_class.define_method(:write_bytes!, orig)
      end
    end

    assert_equal existing, @model.hive_model.new_idea_buffer
    assert_equal [], @model.hive_model.new_idea_attachments
    assert_match(/buffer full/i, @model.hive_model.flash.to_s)
    refute write_called, "BubbleModel#stage_image must gate BEFORE writing the staging file"
  ensure
    Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
  end

  def test_new_idea_image_paste_write_failure_flashes_without_placeholder
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    probe_result = clipboard_image_bytes

    with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
      with_composer_ensure_dir_stub(->(_model) { raise Errno::ENOSPC, "No space left" }) do
        @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
      end
    end

    assert_equal "", @model.hive_model.new_idea_buffer
    assert_equal [], @model.hive_model.new_idea_attachments
    assert_match(/image paste failed/i, @model.hive_model.flash.to_s)
  end

  def test_new_idea_drag_drop_non_image_file_flashes_without_placeholder
    with_tmp_dir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "not an image")
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
        dispatch: @dispatch
      )
      probe_result = clipboard_none

      with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
        @model.update(Hive::Tui::Messages::RawTextInput.new(text: path, paste: true))
      end

      assert_equal "", @model.hive_model.new_idea_buffer
      assert_equal [], @model.hive_model.new_idea_attachments
      assert_match(/not an image/i, @model.hive_model.flash.to_s)
    end
  end

  def test_new_idea_cancel_cleans_staging_dir_and_clears_attachment_state
    dir = Dir.mktmpdir("hive-tui-composer-test-")
    File.write(File.join(dir, "image-1.png"), "image")
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: File.join(dir, "image-1.png"),
      ext: "png"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        new_idea_buffer: "[image1]",
        new_idea_cursor: 8,
        new_idea_attachments: [ attachment ],
        new_idea_staging_dir: dir
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::NEW_IDEA_CANCELLED)

    refute File.exist?(dir)
    assert_equal :grid, @model.hive_model.mode
    assert_equal [], @model.hive_model.new_idea_attachments
    assert_nil @model.hive_model.new_idea_staging_dir
  end

  def test_new_idea_submission_with_empty_buffer_flashes_and_stays_in_new_idea
    # Plan §U6: empty/whitespace title flashes "title required" and
    # STAYS in :new_idea mode so the operator can keep typing without
    # re-opening via `n` after a fat-finger Enter. The buffer is
    # preserved (strip is validation-only) so any leading whitespace
    # the operator typed isn't lost.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "   "
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "empty/whitespace buffer must NOT spawn a subprocess"
    assert_equal :new_idea, @model.hive_model.mode,
                 "fat-finger Enter must NOT close the prompt"
    assert_equal "   ", @model.hive_model.new_idea_buffer,
                 "buffer is preserved so the operator's typing isn't lost"
    assert_match(/title required/, @model.hive_model.flash.to_s)
  end

  def test_new_idea_submission_with_unhealthy_project_flashes_specific_error
    # When `demo` is registered but its path is gone (a stale
    # registration after `rm -rf`), submit must NOT dispatch to a
    # doomed `bin/hive new` — the resulting subprocess would partially
    # write idea.md then fail at `git add` against the missing dir.
    # The flash must name the actual problem so the operator can
    # `hive deregister` or re-init.
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [
        { "name" => "demo", "error" => "missing_project_path", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 1, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "must NOT dispatch against a project with error: state"
    assert_match(/demo.*missing project path/, @model.hive_model.flash.to_s,
                 "flash must name the project AND the specific error")
  end

  # NEW-2: all-unhealthy flash used to unconditionally suggest X / `hive
  # prune`, but those only drop `missing_project_path` rows. With every
  # project at `not_initialised`, the suggestion would land the operator
  # on refusal flashes. The fix branches on the error mix.
  def test_all_unhealthy_flash_points_at_prune_when_every_error_is_missing_path
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-05",
      "projects" => [
        { "name" => "a", "error" => "missing_project_path", "tasks" => [] },
        { "name" => "b", "error" => "missing_project_path", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    assert_match(/press X/i, @model.hive_model.flash.to_s,
                 "missing-only set must steer the operator at the X-key + hive prune surfaces")
  end

  def test_all_unhealthy_flash_points_at_forget_when_errors_mix
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-05",
      "projects" => [
        { "name" => "a", "error" => "missing_project_path", "tasks" => [] },
        { "name" => "b", "error" => "not_initialised", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    refute_match(/press X/i, @model.hive_model.flash.to_s,
                 "mixed-error set must NOT suggest X (which only drops missing-path rows)")
    assert_match(/hive forget|re-init/i, @model.hive_model.flash.to_s,
                 "mixed-error set must point at re-init or per-name `hive forget`")
  end

  # new_idea_project_name points to a project that exists in the
  # snapshot but has an error — the picker chose it before the snapshot
  # poll dropped its health. Submission must flash the per-project error
  # + "choose another project" rather than dispatch against a broken project.
  def test_new_idea_submission_with_chosen_project_now_unhealthy_flashes_choose_another
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-06",
      "projects" => [
        { "name" => "alpha", "tasks" => [] },
        { "name" => "beta", "error" => "not_initialised", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0,
        new_idea_project_name: "beta", new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "must NOT dispatch when the chosen project went unhealthy under us"
    assert_match(/"beta".*not initialised.*choose another project/i, @model.hive_model.flash.to_s,
                 "flash must name the chosen project, the specific error, and steer to a new pick")
    assert_equal :new_idea_project, @model.hive_model.mode,
                 "must bounce back to the picker so operator can re-pick without retyping"
    assert_nil @model.hive_model.new_idea_project_name,
               "stale project name must be cleared on bounce"
    assert_equal "an idea", @model.hive_model.new_idea_buffer,
                 "typed buffer must survive the bounce so the re-pick doesn't cost retyping"
  end

  # new_idea_project_name points to a name no longer in the snapshot
  # (project was removed between picker selection and submit). Submission
  # must flash "is not available — choose another".
  def test_new_idea_submission_with_chosen_project_missing_from_snapshot_flashes_unavailable
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-06",
      "projects" => [
        { "name" => "alpha", "tasks" => [] }
      ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, scope: 0,
        new_idea_project_name: "ghost", new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count, "must NOT dispatch when the chosen project disappeared from snapshot"
    assert_match(/"ghost".*not available.*choose another project/i, @model.hive_model.flash.to_s,
                 "flash must say the chosen name is not available and steer to a new pick")
    assert_equal :new_idea_project, @model.hive_model.mode,
                 "must bounce back to the picker so operator can re-pick without retyping"
    assert_nil @model.hive_model.new_idea_project_name,
               "stale project name must be cleared on bounce"
    assert_equal "an idea", @model.hive_model.new_idea_buffer,
                 "typed buffer must survive the bounce so the re-pick doesn't cost retyping"
  end

  def test_new_idea_submission_with_no_projects_flashes_and_does_not_dispatch
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01", "projects" => []
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    spawn_count = 0
    with_run_quiet_stub(->(_argv) { spawn_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal 0, spawn_count
    assert_match(/no projects/, @model.hive_model.flash.to_s)
  end

  # Regression for the rescue path in submit_new_idea. Errno::E2BIG
  # (oversized argv), ArgumentError (downstream model.with typo), or
  # Encoding::CompatibilityError (weird bytes) all bubble out of
  # run_quiet!. The rescue must flash a useful message AND preserve
  # the typed buffer + :new_idea mode so the operator can retry
  # without retyping — consistent with the empty-title UX, NOT the
  # validation-failure UX which clears the buffer.
  def test_new_idea_submission_rescues_subprocess_exception_and_preserves_buffer
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_project_name: "hive",
        new_idea_buffer: "rss feeds"
      ),
      dispatch: @dispatch
    )
    with_run_quiet_stub(->(_argv) { raise Errno::E2BIG, "Argument list too long" }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_equal :new_idea, @model.hive_model.mode,
                 "rescue path must keep operator in :new_idea, not clobber to :grid"
    assert_equal "rss feeds", @model.hive_model.new_idea_buffer,
                 "rescue path must preserve typed buffer (don't make the user retype)"
    assert_match(/new failed.*E2BIG/, @model.hive_model.flash.to_s,
                 "flash must surface the actionable error class")
  end

  def test_new_idea_submission_subprocess_failure_surfaces_in_flash
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea, snapshot: snap, new_idea_project_name: "hive",
        new_idea_buffer: "an idea"
      ),
      dispatch: @dispatch
    )
    with_run_quiet_stub(->(_argv) { [ 1, "", "boom: bad name\n" ] }) do
      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)
    end
    assert_match(/new failed/, @model.hive_model.flash.to_s)
    assert_match(/boom: bad name/, @model.hive_model.flash.to_s)
    assert_equal :grid, @model.hive_model.mode, "failure still returns to :grid"
  end

  def test_rich_new_idea_submit_blocks_placeholder_without_attachment
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        snapshot: snap,
        new_idea_project_name: "hive",
        new_idea_buffer: "see [image1]",
        new_idea_cursor: 12
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)

    assert_equal :new_idea, @model.hive_model.mode
    assert_equal "see [image1]", @model.hive_model.new_idea_buffer
    assert_equal [ "image1" ], @model.hive_model.new_idea_broken_labels
    assert_match(/broken image placeholder: image1/, @model.hive_model.flash.to_s)
  end

  def test_rich_new_idea_submit_blocks_orphan_attachment
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: "/tmp/hive-tui-composer/image-1.png",
      ext: "png"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        new_idea_buffer: "plain text",
        new_idea_attachments: [ attachment ]
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)

    assert_equal :new_idea, @model.hive_model.mode
    assert_equal [ "image1" ], @model.hive_model.new_idea_broken_labels
    assert_match(/broken image placeholder: image1/, @model.hive_model.flash.to_s)
  end

  def test_rich_new_idea_submit_blocks_missing_staging_file
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: "/tmp/hive-tui-composer/missing-image-1.png",
      ext: "png"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        new_idea_buffer: "see [image1]",
        new_idea_attachments: [ attachment ]
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)

    assert_equal :new_idea, @model.hive_model.mode
    assert_equal [ "image1" ], @model.hive_model.new_idea_broken_labels
    assert_match(/broken image placeholder: image1/, @model.hive_model.flash.to_s)
  end

  def test_new_idea_text_edit_clears_broken_placeholder_highlight
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        new_idea_buffer: "see [image1]",
        new_idea_cursor: "see [image1]".length,
        new_idea_broken_labels: [ "image1" ]
      ),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::RawTextInput.new(text: "!", paste: false))

    assert_equal [], @model.hive_model.new_idea_broken_labels
  end

  def test_rich_new_idea_submit_project_not_found_preserves_buffer_and_attachments
    with_tmp_global_config do
      with_tmp_dir do |dir|
        staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
        staging_path = File.join(staging_dir, "image-1.png")
        File.binwrite(staging_path, "image".b)
        attachment = Hive::Tui::Model::Attachment.new(
          label: "image1",
          staging_path: staging_path,
          ext: "png"
        )
        snap = Hive::Tui::Snapshot.from_payload(
          "generated_at" => "2026-05-01",
          "projects" => [ { "name" => "ghost", "tasks" => [] } ]
        )
        @model = Hive::Tui::BubbleModel.new(
          hive_model: Hive::Tui::Model.initial.with(
            mode: :new_idea,
            snapshot: snap,
            new_idea_project_name: "ghost",
            new_idea_buffer: "see [image1]",
            new_idea_cursor: 12,
            new_idea_attachments: [ attachment ],
            new_idea_staging_dir: staging_dir
          ),
          dispatch: @dispatch
        )

        capture_io { @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }

        assert_equal :new_idea, @model.hive_model.mode
        assert_equal "see [image1]", @model.hive_model.new_idea_buffer
        assert_equal [ attachment ], @model.hive_model.new_idea_attachments
        assert File.exist?(staging_path)
        assert_match(/project not initialized/, @model.hive_model.flash.to_s)
      ensure
        Hive::Tui::ComposerStaging.cleanup!(staging_dir) if staging_dir
      end
    end
  end

  # ---- Rich-submit rescue branches ----
  # Each named class in submit_rich_new_idea's rescue list deserves a
  # direct test so a future narrowing of the list lands as a regression
  # rather than a backtrace-on-submit when the user pastes images.
  def rich_submit_with_raise(raise_proc)
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-13",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
    staging_path = File.join(staging_dir, "image-1.png")
    File.binwrite(staging_path, "x".b)
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: staging_path,
      ext: "png"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        snapshot: snap,
        new_idea_project_name: "hive",
        new_idea_buffer: "title [image1]",
        new_idea_cursor: 14,
        new_idea_attachments: [ attachment ],
        new_idea_staging_dir: staging_dir
      ),
      dispatch: @dispatch
    )
    sentinel = Hive::Commands::New.instance_method(:call!)
    Hive::Commands::New.define_method(:call!, &raise_proc)
    begin
      capture_io { @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }
    ensure
      Hive::Commands::New.define_method(:call!, sentinel)
      Hive::Tui::ComposerStaging.cleanup!(staging_dir) if File.exist?(staging_dir)
    end
  end

  def test_rich_submit_rescues_invalid_slug_error_and_preserves_buffer
    rich_submit_with_raise(-> { raise Hive::Commands::New::InvalidSlugError, "bad slug" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/bad slug/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_rescues_invalid_attachment_error
    rich_submit_with_raise(-> { raise Hive::Commands::New::InvalidAttachmentError, "bad attachment" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/bad attachment/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_rescues_slug_collision_error
    rich_submit_with_raise(-> { raise Hive::Commands::New::SlugCollisionError, "collision" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/collision/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_rescues_system_call_error
    rich_submit_with_raise(-> { raise Errno::ENOSPC, "No space left" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/No space left/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_rescues_ioerror
    rich_submit_with_raise(-> { raise IOError, "stream closed" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/stream closed/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_rescues_write_error_from_staging
    rich_submit_with_raise(-> { raise Hive::Tui::ComposerStaging::WriteError.new("write failed", cause_class: Errno::EACCES) })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/write failed/, @model.hive_model.flash.to_s)
  end

  def test_rich_submit_truncates_long_flash_with_ellipsis
    long_msg = "x" * 300
    rich_submit_with_raise(-> { raise Hive::Commands::New::InvalidSlugError, long_msg })
    flash = @model.hive_model.flash.to_s
    assert_includes flash, "…", "long messages should be truncated with an ellipsis"
    assert flash.length <= 200, "truncated flash should not exceed 200 chars"
  end

  # The renderer fetches attachments by label via `attachments.fetch(label)`
  # which raises KeyError on a buffer/attachment desync. Validate that the
  # rescue list catches it instead of crashing the bubbletea loop.
  def test_rich_submit_rescues_key_error_from_renderer
    rich_submit_with_raise(-> { raise KeyError, "key not found: \"image99\"" })
    assert_equal :new_idea, @model.hive_model.mode
    assert_match(/key not found/, @model.hive_model.flash.to_s)
  end

  # Programmer-error path (NoMethodError, etc.) bypasses the typed
  # rescue list inside `submit_rich_new_idea`, fires the `ensure`
  # cleanup, then propagates to the outer `BubbleModel#update` rescue.
  # That outer rescue preserves model state apart from the flash, so
  # without an explicit `new_idea_staging_dir` reset the next paste
  # would short-circuit through `ensure_dir!` to the now-deleted dir
  # and ENOENT on the first write. Pin the reset here so a future
  # ensure-block edit can't silently regress it.
  def test_rich_submit_programmer_error_clears_model_staging_dir
    rich_submit_with_raise(-> { raise NoMethodError, "undefined method `foo'" })
    assert_nil @model.hive_model.new_idea_staging_dir,
      "programmer-error path must clear the model's staging_dir " \
      "after the ensure-block cleanup removes the disk tmpdir"
    assert_match(/internal error/, @model.hive_model.flash.to_s)
  end

  # ---- DispatchCommand → background spawn ----

  def test_dispatch_command_message_returns_nil_cmd_and_does_not_block
    # Background dispatch returns nil — the TUI keeps its render loop
    # going while the agent runs in parallel. The reaper Thread sends
    # SubprocessExited later via the `dispatch` lambda.
    started = Time.now
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo", "hi" ], verb: "hi")
    _, cmd = @model.update(msg)
    elapsed = Time.now - started
    assert_nil cmd, "DispatchCommand spawns in the background; no Bubbletea Cmd returned"
    assert elapsed < 0.5,
      "update must NOT block on the spawn (got #{elapsed}s — should be < 0.5s)"
  end

  def test_dispatch_command_routes_interactive_verbs_to_foreground_takeover
    # Override `verb_interactive?` on this BubbleModel INSTANCE so the
    # routing path is testable without hard-flagging a real verb in
    # `Hive::Workflows::VERBS` and without mutating module-level state
    # that other tests may read. Per-instance singleton method lives
    # only for the lifetime of @model.
    @model.define_singleton_method(:verb_interactive?) { |verb| verb.to_s == "develop" }

    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug", "--project", "demo", "--from", "3-plan" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    assert_kind_of Bubbletea::SequenceCommand, cmd,
      "interactive verbs route to takeover_command which returns a SequenceCommand " \
      "wrapping exit_alt → exec → enter_alt"
    classes = cmd.commands.map(&:class)
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      classes
    )
  end

  def test_interactive_takeover_callable_runs_child_and_dispatches_subprocess_exited
    # Asserting the SequenceCommand shape is necessary but not
    # sufficient — the inner ExecCommand callable is what actually
    # spawns the child and dispatches SubprocessExited. Without
    # this test, swapping the callable for a no-op (or breaking
    # the dispatch invocation inside it) would silently pass.
    @model.define_singleton_method(:verb_interactive?) { |verb| verb.to_s == "develop" }
    captured = []
    @model.dispatch = ->(msg) { captured << msg }

    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    exec_cmd = cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    refute_nil exec_cmd, "sequence must contain an ExecCommand"

    exec_cmd.callable.call

    assert_equal 1, captured.length,
      "callable must dispatch exactly one SubprocessExited (success path)"
    assert_kind_of Hive::Tui::Messages::SubprocessExited, captured.first
    assert_equal "develop", captured.first.verb
    assert_equal 0, captured.first.exit_code
  end

  def test_dispatch_command_routes_non_interactive_verbs_to_background_spawn
    # No verb is interactive by default, so the regular DispatchCommand
    # for "develop" must produce nil cmd (background spawn).
    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "slug" ],
      verb: "develop"
    )
    _, cmd = @model.update(msg)
    assert_nil cmd, "headless verbs go to dispatch_background; no Bubbletea Cmd returned"
  end

  def test_workflows_interactive_predicate_defaults_to_false
    require "hive/workflows"
    Hive::Workflows::VERBS.each_key do |verb|
      refute Hive::Workflows.interactive?(verb),
        "verb '#{verb}' must NOT be interactive by default — opt-in only when stdin is genuinely required"
    end
  end

  def test_workflows_interactive_predicate_returns_false_for_unknown_verb
    require "hive/workflows"
    refute Hive::Workflows.interactive?("nonexistent-verb")
  end

  def test_dispatch_command_flashes_running_message_for_immediate_feedback
    # Without the flash, pressing a workflow verb key would
    # produce zero visual feedback because the spawn is asynchronous —
    # the user couldn't tell their keypress did anything. The flash is
    # overwritten by SubprocessExited's success/failure flash on
    # completion.
    #
    # argv[0] is `true` (exits 0, ignores all args) instead of "hive"
    # so the background spawn doesn't actually invoke the user's
    # production `hive` against their real config registry. The flash
    # text builder reads argv[1] / argv[2] (verb / slug) — those stay
    # unchanged so the regex assertion still works. Without this
    # guard, the test would leak `hive develop hello-world-test`
    # invocations into the operator's task store every time the
    # suite ran.
    msg = Hive::Tui::Messages::DispatchCommand.new(
      argv: [ "true", "develop", "hello-world-test", "--project", "demo", "--from", "3-plan" ],
      verb: "develop"
    )
    @model.update(msg)
    refute_nil @model.hive_model.flash, "dispatch must flash immediately so the user sees feedback"
    assert_match(/running.*hive develop.*hello-world-test/, @model.hive_model.flash,
      "flash must name the verb and slug the user dispatched on")
    refute_nil @model.hive_model.flash_set_at, "flash_set_at must stamp for TTL aging"
  end

  # ---- RecoverReview → marker clear + hive run ----
  #
  # The handler is asynchronous: the synchronous return only flashes
  # "review recovery: clearing <detail>…" for markers that can be
  # retried directly; the worker thread runs `hive markers clear` +
  # (on success) `hive run` and dispatches the final `Messages::Flash`
  # via @dispatch. REVIEW_STALE is only retried directly when the
  # highest pass has reviewer files but no escalations-NN.md, which
  # means triage never completed and the same pass can be retried.

  def last_async_flash_text
    flash_msg = @messages.reverse.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    flash_msg&.text.to_s
  end

  def test_recover_review_clears_observed_marker_and_reruns_hive_run
    folder = "/tmp/hive/recover-me"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "recover-me",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "phase" => "triage", "reason" => "triage_failed", "pass" => "2" },
      suggested_command: nil
    )
    clear_argv = nil
    run_argv = nil

    with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal [
      "hive", "markers", "clear", folder,
      "--name", "REVIEW_ERROR",
      "--match-attr", "pass=2"
    ], clear_argv
    assert_equal [ "hive", "run", folder ], run_argv

    sync_flash = @model.hive_model.flash.to_s
    assert_match(/clearing/, sync_flash, "synchronous flash must announce the in-progress clear")
    assert_match(/REVIEW_ERROR/, sync_flash)
    assert_match(/phase=triage/, sync_flash)
    assert_match(/reason=triage_failed/, sync_flash)
    assert_match(/pass=2/, sync_flash)

    final_flash = last_async_flash_text
    assert_match(/REVIEW_ERROR/, final_flash, "async flash must echo the cleared marker")
    assert_match(/running.*hive run/, final_flash, "async flash must announce the rerun")
  end

  def test_recover_review_does_not_rerun_when_marker_clear_fails
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "recover-me",
      stage: "6-review",
      folder: "/tmp/hive/recover-me",
      marker: "review_error",
      attrs: { "reason" => "triage_failed", "pass" => "3" },
      suggested_command: nil
    )
    run_count = 0

    with_run_quiet_stub(->(_argv) { [ 4, "", "attr \"pass\" mismatch\n" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { run_count += 1; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal 0, run_count, "hive run must not dispatch when marker clear exits non-zero"
    final_flash = last_async_flash_text
    assert_match(/review recovery failed/, final_flash)
    assert_match(/attr "pass" mismatch/, final_flash)
  end

  def test_recover_review_stale_max_passes_hit_routes_to_browse_not_recover
    # max_passes-hit REVIEW_STALE no longer flashes the manual recipe;
    # it routes through open_review_stale_file (browse via foreground
    # takeover). The clear+rerun path must NOT fire — that's the
    # contract this test pins. Folder doesn't exist on disk here, so
    # the path resolver returns "" and the handler emits the
    # "no review files for <slug>" refusal flash (still no clear, no
    # rerun — the invariant we care about).
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "stale-review",
      stage: "6-review",
      folder: "/tmp/hive/stale-review",
      marker: "review_stale",
      attrs: { "pass" => "4" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "REVIEW_STALE max_passes-hit recovery must not clear the marker"
    refute ran_dispatch, "REVIEW_STALE max_passes-hit recovery must not rerun"
    assert_match(/no review files for stale-review/, @model.hive_model.flash.to_s,
                 "missing folder must flash refusal, not the legacy manual-recipe text")
  end

  def test_recover_review_stale_max_passes_hit_force_clears_and_reruns
    # `r` verb-key path on a max_passes-hit REVIEW_STALE row emits
    # `RecoverReview.new(row:, force: true)`. The bypass skips the
    # `retryable_review_stale?` gate (which would otherwise route to
    # OpenReviewStaleFile browse) and falls through to clear+rerun.
    # The operator's `r` press declares "edits are done, retry now."
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "force-retry-slug",
      stage: "6-review",
      folder: "/tmp/hive/force-retry-slug",
      marker: "review_stale",
      attrs: { "pass" => "4" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false
    clear_argv = nil
    dispatch_argv = nil

    with_run_quiet_stub(->(argv) { ran_clear = true; clear_argv = argv; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(argv, **_kwargs) { ran_dispatch = true; dispatch_argv = argv; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row, force: true))
        @model.wait_for_background_threads
      end
    end

    assert ran_clear, "force-retry must clear the REVIEW_STALE marker"
    assert ran_dispatch, "force-retry must dispatch hive run after the clear"
    assert_includes clear_argv, "REVIEW_STALE",
                    "clear must target the REVIEW_STALE marker (got #{clear_argv.inspect})"
    assert_equal [ "hive", "run", "/tmp/hive/force-retry-slug" ], dispatch_argv,
                 "rerun must invoke `hive run <folder>` (got #{dispatch_argv.inspect})"
  end

  def test_recover_review_stale_force_false_still_routes_to_browse
    # Default `force: false` (Enter-driven, not `r`-driven) preserves
    # the existing browse-not-retry behavior. This guards against an
    # accidental flip of the default value.
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "browse-not-retry",
      stage: "6-review",
      folder: "/tmp/hive/browse-not-retry",
      marker: "review_stale",
      attrs: { "pass" => "4" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row, force: false))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "Enter-driven recovery (force: false) must NOT clear the marker"
    refute ran_dispatch, "Enter-driven recovery (force: false) must NOT dispatch hive run"
  end

  def test_recover_review_stale_with_incomplete_triage_pass_clears_and_reruns
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "claude-ce-code-review-04.md"), "## High\n- [ ] x\n")

      row = make_task_row(
        action_key: "recover_review",
        action_label: "Needs recovery",
        slug: "stale-review",
        stage: "6-review",
        folder: dir,
        marker: "review_stale",
        attrs: { "pass" => "4" },
        suggested_command: nil
      )
      clear_argv = nil
      run_argv = nil

      with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
        with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
          @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
          @model.wait_for_background_threads
        end
      end

      assert_equal [
        "hive", "markers", "clear", dir,
        "--name", "REVIEW_STALE",
        "--match-attr", "pass=4"
      ], clear_argv
      assert_equal [ "hive", "run", dir ], run_argv

      final_flash = last_async_flash_text
      assert_match(/REVIEW_STALE/, final_flash)
      assert_match(/running.*hive run/, final_flash)
    end
  end

  def test_recover_review_stale_does_not_treat_fix_success_as_reviewer_file
    # fix-success-NN.md is an orchestrator sentinel, not a reviewer
    # file — its presence must not trip retryable_incomplete_triage_pass?
    # into clearing+rerunning. With max_passes-hit now routing to
    # open_review_stale_file, the path resolver falls back to the
    # `reviews/` directory when escalations-NN.md is missing, so the
    # handler returns a SequenceCommand (takeover) and the flash
    # names the browse intent. Clear must still NOT fire.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "fix-success-04.md"), "ok\n")

      row = make_task_row(
        action_key: "recover_review",
        action_label: "Needs recovery",
        slug: "stale-review",
        stage: "6-review",
        folder: dir,
        marker: "review_stale",
        attrs: { "pass" => "4" },
        suggested_command: nil
      )
      ran_clear = false
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end

      refute ran_clear, "fix-success-NN.md is an orchestrator sentinel, not a retryable reviewer file"
      # No escalations-04.md exists (only fix-success-04.md, which is
      # in ORCHESTRATOR_OWNED_PREFIXES — not a reviewer file). Resolver
      # falls back to the reviews/ dir and the differentiated flash
      # tells the operator the focal file is missing.
      assert_match(/opening reviews\/ dir for stale-review/, @model.hive_model.flash.to_s,
                   "max_passes-hit dir-fallback must use the differentiated flash, not the legacy recipe")
    end
  end

  def test_recover_review_stale_wall_clock_clears_and_reruns_without_reviewer_files
    # REVIEW_STALE reason=wall_clock can be set by the runner BEFORE
    # any reviewer files exist (e.g. wall-clock fired during Phase 1
    # CI-fix). Pre-fix, the TUI's retryable_incomplete_triage_pass?
    # gate required reviewer files to be present, so wall-clock stale
    # without files fell into the manual-cleanup flash that told the
    # operator to "edit/rename highest-pass review files" — which
    # don't exist. Now wall-clock stale is explicitly retryable
    # regardless of reviewer-file presence.
    with_tmp_dir do |dir|
      # reviews/ may or may not exist; explicitly leave it absent to
      # match the worst-case (Phase 1 wall-clock).
      row = make_task_row(
        action_key: "recover_review",
        action_label: "Needs recovery",
        slug: "wall-clock-stale",
        stage: "6-review",
        folder: dir,
        marker: "review_stale",
        attrs: { "reason" => "wall_clock", "pass" => "1", "elapsed" => "5400" },
        suggested_command: nil
      )
      clear_argv = nil
      run_argv = nil

      with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
        with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
          @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
          @model.wait_for_background_threads
        end
      end

      refute_nil clear_argv,
                 "wall-clock REVIEW_STALE must trigger the markers-clear path " \
                 "(no manual file cleanup is needed; the operator just wants more time)"
      assert_equal [
        "hive", "markers", "clear", dir,
        "--name", "REVIEW_STALE",
        "--match-attr", "pass=1"
      ], clear_argv
      assert_equal [ "hive", "run", dir ], run_argv

      # `assert_equal clear_argv` + `assert_equal run_argv` above carry
      # the real load — they pin that the wall_clock path took the
      # clear+rerun branch, not the browse branch. The previous
      # `refute_match(/manual pass cleanup/)` lines were dropped after
      # PR #66 deleted the `review_stale_recovery_message` helper —
      # the regex could no longer match anything regardless, so the
      # assertion was vacuously true (always passing).
    end
  end

  def test_recover_review_flashes_partial_failure_when_dispatch_raises_after_clear_succeeds
    folder = "/tmp/hive/partial-failure"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "partial-failure",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "reason" => "triage_failed", "pass" => "2" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { raise Errno::ENOENT, "no such file - hive" }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    final_flash = last_async_flash_text
    assert_match(/marker cleared/, final_flash,
                 "partial-failure flash must explicitly say the marker WAS cleared")
    assert_match(/hive run.*failed to start/, final_flash,
                 "partial-failure flash must say the rerun did not start")
    assert_match(/run `hive run #{Regexp.escape(folder)}` manually/, final_flash,
                 "partial-failure flash must give the operator the manual recovery command")
  end

  def test_recover_review_flashes_when_folder_missing
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "no-folder",
      stage: "6-review",
      folder: "",
      marker: "review_error",
      attrs: { "reason" => "triage_failed" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "marker clear must not run when folder is missing"
    refute ran_dispatch, "hive run must not dispatch when folder is missing"
    assert_match(/task folder missing/, @model.hive_model.flash.to_s)
  end

  def test_recover_review_flashes_when_marker_not_recoverable
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "unknown-marker",
      stage: "6-review",
      folder: "/tmp/hive/unknown-marker",
      marker: "review_timeout",
      attrs: { "reason" => "future_marker" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "marker clear must not run for an unknown marker"
    refute ran_dispatch, "hive run must not dispatch for an unknown marker"
    assert_match(/review recovery unavailable/, @model.hive_model.flash.to_s)
    assert_match(/marker=review_timeout/, @model.hive_model.flash.to_s)
  end

  def test_recover_review_catches_io_failure_from_run_quiet
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "io-fail",
      stage: "6-review",
      folder: "/tmp/hive/io-fail",
      marker: "review_error",
      attrs: { "reason" => "triage_failed" },
      suggested_command: nil
    )
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { raise Errno::ENOENT, "no such file - hive" }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_dispatch, "hive run must not dispatch when run_quiet! raises"
    final_flash = last_async_flash_text
    assert_match(/review recovery failed/, final_flash)
    assert_match(/Errno::ENOENT/, final_flash,
                 "narrow rescue must surface the SystemCallError class so logs are actionable")
  end

  def test_recover_review_does_not_swallow_programmer_errors_from_worker
    # The narrow rescue catches SystemCallError / IOError /
    # Subprocess::TimeoutError only — NoMethodError and friends crash
    # the worker thread loud, so the operator never sees a misleading
    # "review recovery failed" flash for what is actually a logic bug.
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "logic-bug",
      stage: "6-review",
      folder: "/tmp/hive/logic-bug",
      marker: "review_error",
      attrs: { "reason" => "triage_failed" },
      suggested_command: nil
    )

    Thread.report_on_exception = false
    begin
      with_run_quiet_stub(->(_argv) { raise NoMethodError, "undefined method `frob` for nil" }) do
        with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
          @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
          @model.wait_for_background_threads
        end
      end
    ensure
      Thread.report_on_exception = true
    end

    flash_messages = @messages.select { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    refute(
      flash_messages.any? { |m| m.text.to_s.include?("review recovery failed") },
      "programmer errors must NOT be swallowed into a 'review recovery failed' flash"
    )
  end

  def test_recover_review_dedups_concurrent_attempts_on_same_folder
    folder = "/tmp/hive/dedup-me"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "dedup-me",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "reason" => "triage_failed", "pass" => "2" },
      suggested_command: nil
    )
    # Block the worker on a latch so the second Enter sees an
    # in-flight slot. Without the latch, the first worker can
    # finish and evict the slot before the second message arrives,
    # turning a real-life double-Enter race into an ordered pair.
    latch = Queue.new
    clear_calls = 0

    stub = lambda do |_argv|
      clear_calls += 1
      latch.pop # block until the test releases
      [ 0, "", "" ]
    end

    with_run_quiet_stub(stub) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        # Second Enter while the first worker is blocked inside run_quiet!.
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        latch << :go
        @model.wait_for_background_threads
      end
    end

    assert_equal 1, clear_calls, "second Enter on same folder must be deduped while first is in flight"
    assert_match(/already in progress/, @model.hive_model.flash.to_s,
                 "second Enter must flash an 'already in progress' refusal synchronously")
  end

  def test_recover_review_sanitizes_control_chars_and_ansi_in_flash_detail
    folder = "/tmp/hive/sanitize-me"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "sanitize-me",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "reason" => "bad\x1b[31mansi\x1b[0m\nNL", "pass" => "2" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    sync_flash = @model.hive_model.flash.to_s
    refute_match(/\e\[/, sync_flash, "ANSI CSI escapes must be stripped from the flash detail")
    refute_match(/\n/, sync_flash, "embedded newlines must not appear in the flash detail")
    refute_match(/\x7f/, sync_flash, "control bytes must not appear in the flash detail")
    final_flash = last_async_flash_text
    refute_match(/\e\[/, final_flash, "ANSI CSI escapes must be stripped from the async flash")
    refute_match(/\n/, final_flash, "embedded newlines must not appear in the async flash")
  end

  def test_recover_review_omits_match_attr_when_no_recoverable_attrs
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "no-attrs",
      stage: "6-review",
      folder: "/tmp/hive/no-attrs",
      marker: "review_error",
      attrs: {},
      suggested_command: nil
    )
    clear_argv = nil
    run_argv = nil

    with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal [
      "hive", "markers", "clear", "/tmp/hive/no-attrs",
      "--name", "REVIEW_ERROR"
    ], clear_argv, "argv must omit --match-attr when no REVIEW_RECOVERY_MATCH_ATTRS keys are present"
    assert_equal [ "hive", "run", "/tmp/hive/no-attrs" ], run_argv
    flash = @model.hive_model.flash.to_s
    assert_match(/REVIEW_ERROR/, flash, "flash must include marker name")
    refute_match(/REVIEW_ERROR \S/, flash, "flash must not append attr pairs after marker name when attrs is empty")
  end

  def test_recover_review_detail_appends_unknown_attrs_sorted
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "extra-attrs",
      stage: "6-review",
      folder: "/tmp/hive/extra-attrs",
      marker: "review_error",
      attrs: { "reason" => "triage_failed", "zebra" => "z", "apple" => "a" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    flash = @model.hive_model.flash.to_s
    reason_idx = flash.index("reason=triage_failed")
    apple_idx = flash.index("apple=a")
    zebra_idx = flash.index("zebra=z")
    refute_nil reason_idx
    refute_nil apple_idx
    refute_nil zebra_idx
    assert reason_idx < apple_idx, "known DETAIL_ATTRS keys must appear before extra keys"
    assert apple_idx < zebra_idx, "extra keys must be appended in sorted order"
  end

  # ---- RecoverError → ERROR-marker clear + hive run ----
  #
  # Mirrors the RecoverReview block above. Same async contract: the
  # synchronous return only flashes "error recovery: clearing <detail>…",
  # the worker thread runs `hive markers clear --name ERROR` + (on
  # success) `hive run`. Tests must call `wait_for_background_threads`
  # before asserting on stub captures or dispatched flashes.

  def test_recover_error_clears_observed_marker_and_reruns_hive_run
    folder = "/tmp/hive/error-me"
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      slug: "error-me",
      stage: "3-plan",
      folder: folder,
      marker: "error",
      attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    clear_argv = nil
    run_argv = nil

    with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal [
      "hive", "markers", "clear", folder,
      "--name", "ERROR",
      "--match-attr", "exit_code=1"
    ], clear_argv, "argv must clear ERROR with --match-attr exit_code=N to avoid erasing fresher real failures"
    assert_equal [ "hive", "run", folder ], run_argv

    sync_flash = @model.hive_model.flash.to_s
    assert_match(/clearing/, sync_flash, "synchronous flash must announce the in-progress clear")
    assert_match(/ERROR/, sync_flash)
    assert_match(/reason=exit_code/, sync_flash)
    assert_match(/exit_code=1/, sync_flash)

    final_flash = last_async_flash_text
    assert_match(/ERROR/, final_flash, "async flash must echo the cleared marker")
    assert_match(/running.*hive run/, final_flash, "async flash must announce the rerun")
  end

  def test_red_status_autofix_dispatches_markerless_diagnostic_retry_without_marker_clear
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      slug: "plan-task-260519-abcd",
      stage: "3-plan",
      marker: "none",
      attrs: {},
      suggested_command: nil
    )
    diagnostic = {
      "summary" => "PLAN_MISSING_OUTPUT",
      "suggested_next_action" => {
        "kind" => "retry",
        "command" => "hive plan plan-task-260519-abcd --from 3-plan"
      }
    }
    row = row.with(diagnostic: diagnostic)
    clear_count = 0
    run_argv = nil

    with_run_quiet_stub(->(_argv) { clear_count += 1; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(argv, **_kwargs) { run_argv = argv; nil }) do
        @model.update(Hive::Tui::Messages::RedStatusAutofix.new(row: row))
      end
    end

    assert_equal 0, clear_count, "markerless synthetic errors must not try to clear ERROR"
    assert_equal [ "hive", "plan", "plan-task-260519-abcd", "--from", "3-plan" ], run_argv
    assert_match(/running.*hive plan.*plan-task-260519-abcd/, @model.hive_model.flash)
  end

  def test_red_status_autofix_refuses_markerless_manual_fix
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      slug: "finalize-task-260519-abcd",
      stage: "7-finalize",
      marker: "none",
      attrs: {},
      suggested_command: nil
    )
    row = row.with(
      diagnostic: {
        "summary" => "FINALIZE_MISSING_PR_MD",
        "suggested_next_action" => {
          "kind" => "manual_fix",
          "command" => nil
        }
      }
    )
    clear_count = 0

    with_run_quiet_stub(->(_argv) { clear_count += 1; [ 0, "", "" ] }) do
      @model.update(Hive::Tui::Messages::RedStatusAutofix.new(row: row))
    end

    assert_equal 0, clear_count
    assert_match(/no autofix action available/, @model.hive_model.flash)
  end

  def test_recover_error_does_not_rerun_when_marker_clear_fails
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "error-me", stage: "3-plan", folder: "/tmp/hive/error-me",
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    run_count = 0

    with_run_quiet_stub(->(_argv) { [ 4, "", "attr \"exit_code\" mismatch\n" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { run_count += 1; nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal 0, run_count, "hive run must not dispatch when markers clear exits non-zero"
    final_flash = last_async_flash_text
    assert_match(/error recovery failed/, final_flash)
    assert_match(/exit_code.*mismatch/, final_flash)
  end

  def test_recover_error_flashes_partial_failure_when_dispatch_raises_after_clear_succeeds
    folder = "/tmp/hive/partial-failure"
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "partial-failure", stage: "3-plan", folder: folder,
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { raise Errno::ENOENT, "no such file - hive" }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    final_flash = last_async_flash_text
    assert_match(/marker cleared/, final_flash,
                 "partial-failure flash must explicitly say the marker WAS cleared")
    assert_match(/hive run.*failed to start/, final_flash,
                 "partial-failure flash must say the rerun did not start")
    assert_match(/run `hive run #{Regexp.escape(folder)}` manually/, final_flash,
                 "partial-failure flash must give the operator the manual recovery command")
  end

  def test_recover_error_flashes_when_folder_missing
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "no-folder", stage: "3-plan", folder: "",
      marker: "error", attrs: { "exit_code" => "1" },
      suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "marker clear must not run when folder is missing"
    refute ran_dispatch, "hive run must not dispatch when folder is missing"
    assert_match(/task folder missing/, @model.hive_model.flash.to_s)
  end

  # Kill-class signal kills (130/137/143) are auto-healed in the
  # background by `auto_heal_kill_class_errors`. RecoverError refuses
  # those rows synchronously so the Enter-driven recovery doesn't race
  # the auto-heal on the same markers-lock.
  def test_recover_error_skips_kill_class_exit_codes
    %w[130 137 143].each do |code|
      row = make_task_row(
        action_key: "error", action_label: "Error",
        slug: "killed-#{code}", stage: "3-plan",
        folder: "/tmp/hive/killed-#{code}",
        marker: "error", attrs: { "reason" => "exit_code", "exit_code" => code },
        suggested_command: nil
      )
      ran_clear = false
      with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
        with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
          @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
          @model.wait_for_background_threads
        end
      end
      refute ran_clear, "RecoverError must not clear kill-class markers (auto-heal owns them)"
      assert_match(/kill-class.*auto-heals/, @model.hive_model.flash.to_s,
                   "flash must explain why exit_code=#{code} was refused")
    end
  end

  def test_recover_error_catches_io_failure_from_run_quiet
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "io-fail", stage: "3-plan", folder: "/tmp/hive/io-fail",
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { raise Errno::ENOENT, "no such file - hive" }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_dispatch, "hive run must not dispatch when run_quiet! raises"
    final_flash = last_async_flash_text
    assert_match(/error recovery failed/, final_flash)
    assert_match(/Errno::ENOENT/, final_flash,
                 "narrow rescue must surface the SystemCallError class so logs are actionable")
  end

  def test_recover_error_does_not_swallow_programmer_errors_from_worker
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "logic-bug", stage: "3-plan", folder: "/tmp/hive/logic-bug",
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )

    Thread.report_on_exception = false
    begin
      with_run_quiet_stub(->(_argv) { raise NoMethodError, "undefined method `frob` for nil" }) do
        with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
          @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
          @model.wait_for_background_threads
        end
      end
    ensure
      Thread.report_on_exception = true
    end

    flash_messages = @messages.select { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    refute(
      flash_messages.any? { |m| m.text.to_s.include?("error recovery failed") },
      "programmer errors must NOT be swallowed into an 'error recovery failed' flash"
    )
  end

  def test_recover_error_dedups_concurrent_attempts_on_same_folder
    folder = "/tmp/hive/dedup-error"
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "dedup-error", stage: "3-plan", folder: folder,
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    latch = Queue.new
    clear_calls = 0

    stub = lambda do |_argv|
      clear_calls += 1
      latch.pop
      [ 0, "", "" ]
    end

    with_run_quiet_stub(stub) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        latch << :go
        @model.wait_for_background_threads
      end
    end

    assert_equal 1, clear_calls, "second Enter on same folder must be deduped while first is in flight"
    assert_match(/already in progress/, @model.hive_model.flash.to_s,
                 "second Enter must flash an 'already in progress' refusal synchronously")
  end

  def test_recover_error_omits_match_attr_when_no_exit_code
    # Hand-written / legacy ERROR markers without an exit_code attr take
    # the recovery path (the markers-clear allowlist accepts ERROR), but
    # the argv must omit --match-attr so the clear isn't refused for
    # comparing against an empty value.
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "no-attrs", stage: "3-plan", folder: "/tmp/hive/no-attrs",
      marker: "error", attrs: {}, suggested_command: nil
    )
    clear_argv = nil

    with_run_quiet_stub(->(argv) { clear_argv = argv; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal [
      "hive", "markers", "clear", "/tmp/hive/no-attrs",
      "--name", "ERROR"
    ], clear_argv, "argv must omit --match-attr when the row has no exit_code attr"
  end

  def test_recover_error_sanitizes_control_chars_and_ansi_in_flash_detail
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "sanitize-me", stage: "3-plan", folder: "/tmp/hive/sanitize-me",
      marker: "error",
      attrs: { "reason" => "bad\x1b[31mansi\x1b[0m\nNL", "exit_code" => "1" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    sync_flash = @model.hive_model.flash.to_s
    refute_match(/\e\[/, sync_flash, "ANSI CSI escapes must be stripped from the flash detail")
    refute_match(/\n/, sync_flash, "embedded newlines must not appear in the flash detail")
    final_flash = last_async_flash_text
    refute_match(/\e\[/, final_flash, "ANSI CSI escapes must be stripped from the async flash")
    refute_match(/\n/, final_flash, "embedded newlines must not appear in the async flash")
  end

  # The recover_error handler has a defensive guard that refuses any
  # caller whose `action_key` is not "error". KeyMap only routes
  # `error`-keyed rows to RecoverError today, so the guard is dead in
  # the field — but the distinct flash is a public contract for any
  # future caller (LFG, direct dispatch in a test, programmer error
  # at the orchestrator) and should not silently drift.
  def test_recover_error_flashes_when_action_key_is_not_error
    row = make_task_row(
      action_key: "ready_to_develop", action_label: "Ready to develop",
      slug: "wrong-key", stage: "3-plan", folder: "/tmp/hive/wrong-key",
      marker: "complete", attrs: {}, suggested_command: nil
    )
    ran_clear = false
    ran_dispatch = false

    with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { ran_dispatch = true; nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    refute ran_clear, "marker clear must not run for non-error action keys"
    refute ran_dispatch, "hive run must not dispatch for non-error action keys"
    flash = @model.hive_model.flash.to_s
    assert_match(/error recovery unavailable/, flash)
    assert_match(/action=ready_to_develop/, flash,
                 "refusal flash must echo the actual action_key for debugging")
  end

  # The ERROR_RECOVERY_DETAIL_ATTRS list orders the well-known attrs
  # (reason, exit_code, phase, elapsed); any other attrs are appended
  # alphabetically after them. Tests cover the well-known path via the
  # main recover_error tests but not the alphabetical append, which is
  # the property other agents would step on if they invented new attr
  # names. Mirrors `test_recover_review_detail_appends_unknown_attrs_sorted`.
  def test_recover_error_detail_appends_unknown_attrs_sorted
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "extra-attrs", stage: "3-plan", folder: "/tmp/hive/extra-attrs",
      marker: "error",
      attrs: { "reason" => "exit_code", "exit_code" => "1",
               "zebra" => "z", "apple" => "a" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
        @model.wait_for_background_threads
      end
    end

    flash = @model.hive_model.flash.to_s
    reason_idx = flash.index("reason=exit_code")
    apple_idx = flash.index("apple=a")
    zebra_idx = flash.index("zebra=z")
    refute_nil reason_idx, "flash must include the known reason attr"
    refute_nil apple_idx
    refute_nil zebra_idx
    assert reason_idx < apple_idx, "known DETAIL_ATTRS keys must appear before extra keys"
    assert apple_idx < zebra_idx, "extra keys must be appended in sorted order"
  end

  # ---- OpenInputEditor → foreground editor takeover ----

  def test_open_input_editor_returns_sequence_command_and_dispatches_result
    row = make_task_row(state_file: "/tmp/hive/some-slug/brainstorm.md")
    seen_editor_invocation = nil
    mtime_reads = 0
    @model.define_singleton_method(:editor_argv) { [ "fake-editor", "--wait" ] }
    @model.define_singleton_method(:file_mtime) do |_path|
      mtime_reads += 1
    end
    @model.define_singleton_method(:run_editor) do |argv, path|
      seen_editor_invocation = [ argv, path ]
      0
    end

    _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))

    assert_kind_of Bubbletea::SequenceCommand, cmd
    classes = cmd.commands.map(&:class)
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      classes
    )
    assert_match(/editing some-slug/, @model.hive_model.flash)

    exec_cmd = cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    exec_cmd.callable.call

    assert_equal [ [ "fake-editor", "--wait" ], "/tmp/hive/some-slug/brainstorm.md" ], seen_editor_invocation
    assert_equal 1, @messages.length
    assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first
    assert_equal "some-slug", @messages.first.slug
    assert_equal 0, @messages.first.exit_code
    assert_equal true, @messages.first.changed
    assert_equal 2, mtime_reads
  end

  def test_open_input_editor_for_execute_waiting_uses_next_action_target
    row = make_task_row(
      stage: "4-execute",
      marker: "execute_waiting",
      attrs: { "reason" => "dirty_worktree" },
      state_file: "/tmp/hive/some-slug/task.md",
      next_action: {
        "kind" => Hive::Schemas::NextActionKind::EDIT,
        "target" => "/tmp/hive/some-slug-worktree"
      }
    )
    seen_editor_invocation = nil
    @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
    @model.define_singleton_method(:file_mtime) { |_path| 1.0 }
    @model.define_singleton_method(:run_editor) do |argv, path|
      seen_editor_invocation = [ argv, path ]
      0
    end

    _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
    cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

    assert_equal [ [ "fake-editor" ], "/tmp/hive/some-slug-worktree" ], seen_editor_invocation
  end

  def test_open_input_editor_dispatches_unchanged_when_mtime_is_same
    row = make_task_row(state_file: "/tmp/hive/some-slug/brainstorm.md")
    mtimes = [ 42.0, 42.0 ]
    @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
    @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
    @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

    _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
    cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

    assert_equal false, @messages.first.changed
    assert_empty mtimes
  end

  def test_open_input_editor_auto_dispatches_completed_brainstorm_answers
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        # Brainstorm

        ## Round 2
        ### Q1. Scope?
        ### A1.
        Build the smallest useful slice.
        ### Q2. Cadence?
        ### A2. Daily cron.
        <!-- WAITING -->
      MD
      row = make_task_row(
        slug: "answered-task",
        state_file: brainstorm_md,
        suggested_command: "hive brainstorm answered-task --project demo --from 2-brainstorm"
      )
      mtimes = [ 10.0, 11.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length,
        "auto-continue path must dispatch InputEditorExited then DispatchCommand"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_equal "answered-task", @messages[0].slug
      assert_equal 0, @messages[0].exit_code
      assert_equal true, @messages[0].changed
      assert_kind_of Hive::Tui::Messages::DispatchCommand, @messages[1]
      assert_equal(
        [ "hive", "brainstorm", "answered-task", "--project", "demo", "--from", "2-brainstorm" ],
        @messages[1].argv
      )
      assert_equal "brainstorm", @messages[1].verb
      assert_empty mtimes
    end
  end

  def test_open_input_editor_keeps_partial_brainstorm_answers_manual
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        # Brainstorm

        ## Round 1
        ### Q1. Scope?
        ### A1.
        Answered.
        ### Q2. Cadence?
        ### A2.
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ 20.0, 21.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first
      assert_equal true, @messages.first.changed
      assert_empty mtimes
    end
  end

  def test_open_input_editor_no_auto_dispatch_on_nonzero_exit
    # Pins the `exit_code == 0` half of the auto_continue guard.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ 40.0, 41.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      # Editor aborted (e.g. SIGINT during edit).
      @model.define_singleton_method(:run_editor) { |_argv, _path| 130 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first,
        "non-zero editor exit must NOT auto-dispatch even with completed answers"
      assert_equal 130, @messages.first.exit_code
      assert_empty mtimes
    end
  end

  def test_open_input_editor_no_auto_dispatch_when_mtime_unchanged_with_complete_answers
    # Pins the `&& changed` half of the auto_continue guard against a
    # real fully-answered fixture (the older line-848 test only hit
    # this via ENOENT-rescue accident on a non-existent path).
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ 50.0, 50.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first,
        "unchanged mtime must NOT auto-dispatch even with completed answers"
      assert_equal false, @messages.first.changed
      assert_empty mtimes
    end
  end

  def test_open_input_editor_no_auto_dispatch_when_marker_changed_while_editing
    # Stale row captured before the editor opened. The on-disk marker
    # is fresh and reads `<!-- COMPLETE -->`; the `row.marker` attr is
    # deliberately set to `"complete"` to prove the production code
    # reads from disk via `Hive::Markers.current` and ignores
    # the row attr (otherwise the suppression test could pass for the
    # wrong reason — being driven by the stale row attribute).
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        <!-- COMPLETE -->
      MD
      row = make_task_row(state_file: brainstorm_md, marker: "complete")
      mtimes = [ 70.0, 71.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length,
        "marker race must dispatch [InputEditorExited, suppression Flash]"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_equal true, @messages[0].changed
      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/marker changed during edit/, @messages[1].text)
      assert_empty mtimes
    end
  end

  def test_open_input_editor_no_auto_dispatch_when_marker_is_agent_working
    # Concurrent brainstorm agent picked up answers and is mid-run.
    # Auto-continue must NOT spawn a second `hive brainstorm` against
    # the same slug — that would race the existing process on
    # brainstorm.md.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        <!-- AGENT_WORKING -->
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ 90.0, 91.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_kind_of Hive::Tui::Messages::Flash, @messages[1],
        "AGENT_WORKING marker must trigger marker-changed suppression flash"
      assert_match(/marker changed during edit/, @messages[1].text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
        "AGENT_WORKING marker must NOT auto-dispatch")
    end
  end

  def test_open_input_editor_no_auto_dispatch_when_marker_is_error
    # Brainstorm agent crashed and left the row in :error. Re-running
    # against an unacknowledged error state would silently retry.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        <!-- ERROR -->
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ 95.0, 96.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
        "ERROR marker must NOT auto-dispatch")
    end
  end

  def test_open_input_editor_no_auto_dispatch_when_suggested_command_empty
    # Pins the `suggested_command.to_s.empty?` guard. Without this
    # test, removing the guard would let a nil-suggested_command row
    # crash inside `Shellwords.split(nil)` (TypeError, not caught by
    # the ArgumentError rescue below it).
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      row = make_task_row(state_file: brainstorm_md, suggested_command: "")
      mtimes = [ 80.0, 81.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/no suggested command/, @messages[1].text)
    end
  end

  def test_open_input_editor_treats_nil_mtime_as_no_change
    # A transient ENOENT/EACCES on either mtime sample yields nil.
    # `nil != Float` previously registered as `changed: true` and
    # produced a misleading "edited <slug>" flash even when the user
    # saved nothing. Both samples must be non-nil to claim a change.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      row = make_task_row(state_file: brainstorm_md)
      mtimes = [ nil, 100.0 ] # transient pre-edit ENOENT
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first
      assert_equal false, @messages.first.changed
      assert_empty mtimes
    end
  end

  def test_open_input_editor_falls_back_to_input_editor_exited_on_malformed_suggested_command
    # Exercises the `rescue ArgumentError` branch in
    # input_editor_exit_messages: Shellwords.split raises on
    # unbalanced quotes; auto-continue must NOT crash, and the user
    # still gets the manual-path InputEditorExited.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      row = make_task_row(
        state_file: brainstorm_md,
        # Unbalanced quote → Shellwords.split raises ArgumentError.
        suggested_command: %q(hive brainstorm slug --note 'unclosed)
      )
      mtimes = [ 60.0, 61.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length,
        "malformed suggested_command falls back to manual path + suppression flash"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/malformed suggested command/, @messages[1].text)
      assert_empty mtimes
    end
  end

  def test_open_input_editor_uses_real_file_mtime_when_unstubbed
    # Integration test: do NOT stub file_mtime. Stubbing the seam in
    # other tests is appropriate for unit scope, but means a
    # regression where the real File.mtime returned nil consistently
    # would still pass. This test exercises the real wrapper end-to-end.
    with_tmp_dir do |dir|
      brainstorm_md = File.join(dir, "brainstorm.md")
      File.write(brainstorm_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
      MD
      File.utime(Time.at(1_700_000_000), Time.at(1_700_000_000), brainstorm_md)
      row = make_task_row(
        state_file: brainstorm_md,
        suggested_command: "hive brainstorm slug --from 2-brainstorm"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      # Bump the real mtime forward as the "editor save" side effect.
      @model.define_singleton_method(:run_editor) do |_argv, path|
        File.utime(Time.at(1_700_000_010), Time.at(1_700_000_010), path)
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_equal true, @messages[0].changed
      assert_kind_of Hive::Tui::Messages::DispatchCommand, @messages[1]
    end
  end

  def test_open_input_editor_does_not_auto_dispatch_non_auto_stages
    # Stages other than 2-brainstorm and 3-plan have no auto-continue
    # path; they must always take the manual InputEditorExited route.
    with_tmp_dir do |dir|
      task_md = File.join(dir, "task.md")
      File.write(task_md, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Complete-looking, but this stage has no auto-continue.
      MD
      row = make_task_row(
        stage: "4-execute",
        state_file: task_md,
        suggested_command: "hive develop some-slug --from 4-execute"
      )
      mtimes = [ 30.0, 31.0 ]
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:file_mtime) { |_path| mtimes.shift }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first
      assert_empty mtimes
    end
  end

  # ---- OpenTaskFolder → foreground editor takeover (browse-only) ----

  def test_open_task_folder_returns_sequence_command_and_opens_folder
    # Happy path: a valid row produces the same SequenceCommand shape
    # as OpenInputEditor (alt-screen exit → exec → alt-screen enter),
    # the editor is invoked against `row.folder`, and the flash names
    # the slug + editor binary. Critically, NO InputEditorExited or
    # other follow-up message is dispatched — this is a pure browse
    # gesture, the editor's exit is the user's last word.
    row = make_task_row(folder: "/tmp/hive/some-slug")
    seen_editor_invocation = nil
    @model.define_singleton_method(:editor_argv) { [ "fake-editor", "--wait" ] }
    @model.define_singleton_method(:run_editor) do |argv, path|
      seen_editor_invocation = [ argv, path ]
      0
    end

    _, cmd = @model.update(Hive::Tui::Messages::OpenTaskFolder.new(row: row))

    assert_kind_of Bubbletea::SequenceCommand, cmd
    classes = cmd.commands.map(&:class)
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      classes
    )
    assert_match(/opening some-slug folder in fake-editor/, @model.hive_model.flash)

    exec_cmd = cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    exec_cmd.callable.call

    assert_equal [ [ "fake-editor", "--wait" ], "/tmp/hive/some-slug" ], seen_editor_invocation
    assert_empty @messages,
      "OpenTaskFolder is a pure browse gesture — no follow-up messages should be dispatched"
  end

  def test_open_task_folder_flashes_refusal_when_folder_empty
    # Defensive: R4 requires a flash + no spawn when row.folder is
    # missing/empty. Should never happen for a well-formed row, but
    # the handler-level guard catches it. NOOP would silently fail —
    # the flash tells the user something is wrong.
    row = make_task_row(folder: "")
    _, cmd = @model.update(Hive::Tui::Messages::OpenTaskFolder.new(row: row))

    assert_nil cmd, "no takeover command when folder is empty"
    assert_match(/no task folder for some-slug/, @model.hive_model.flash)
  end

  def test_open_task_folder_flashes_refusal_when_editor_argv_invalid
    # When $VISUAL/$EDITOR/vi all resolve to empty (e.g., user has
    # VISUAL="" exported with no fallback chain), editor_argv raises
    # ArgumentError. Same rescue shape as open_input_editor.
    row = make_task_row(folder: "/tmp/hive/some-slug")
    @model.define_singleton_method(:editor_argv) { raise ArgumentError, "empty $VISUAL/$EDITOR" }

    _, cmd = @model.update(Hive::Tui::Messages::OpenTaskFolder.new(row: row))

    assert_nil cmd
    assert_match(/editor command invalid: empty \$VISUAL\/\$EDITOR/, @model.hive_model.flash)
  end

  def test_open_task_folder_does_not_dispatch_or_mutate_marker
    # R3 by construction: the open_task_folder handler reads only
    # `row.folder` and never touches Hive::Markers or dispatches a
    # follow-up message. Pure browse gesture. The OpenInputEditor
    # path, by contrast, dispatches InputEditorExited on completion.
    row = make_task_row(folder: "/tmp/hive/some-slug")
    @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
    @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

    _, cmd = @model.update(Hive::Tui::Messages::OpenTaskFolder.new(row: row))
    cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

    assert_empty @messages,
      "OpenTaskFolder must not dispatch any follow-up message — no auto-continue, no InputEditorExited"
  end

  # ---- OpenIdeaPreview → bottom-strip preview (read-only) ----

  def test_open_idea_preview_reads_original_text_and_enters_preview_mode
    with_tmp_dir do |dir|
      write_idea_md(dir, original_text: "Build task from user note")
      row = make_task_row(folder: dir, slug: "some-slug")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal "Build task from user note", @model.hive_model.idea_preview_text
      assert_equal "some-slug", @model.hive_model.idea_preview_slug
    end
  end

  def test_open_idea_preview_flashes_when_folder_empty
    row = make_task_row(folder: "")

    _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

    assert_nil cmd
    assert_equal :grid, @model.hive_model.mode
    assert_match(/no idea for some-slug/, @model.hive_model.flash.to_s)
  end

  def test_open_idea_preview_flashes_when_idea_md_missing
    with_tmp_dir do |dir|
      row = make_task_row(folder: dir)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/no idea\.md for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_flashes_when_original_text_missing
    with_tmp_dir do |dir|
      File.write(File.join(dir, "idea.md"), "---\nslug: some-slug\n---\n")
      row = make_task_row(folder: dir)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/idea has no original_text for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_flashes_on_unreadable_idea_md
    with_tmp_dir do |dir|
      File.write(File.join(dir, "idea.md"), "---\noriginal_text: [broken\n---\n")
      row = make_task_row(folder: dir)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/could not read idea for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_does_not_dispatch_or_mutate_marker
    with_tmp_dir do |dir|
      idea_path = write_idea_md(dir, original_text: "Read only")
      before = File.read(idea_path)
      row = make_task_row(folder: dir)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_empty @messages
      assert_equal before, File.read(idea_path)
    end
  end

  def test_open_idea_preview_truncates_oversized_original_text
    with_tmp_dir do |dir|
      original = "x" * (Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS + 20)
      write_idea_md(dir, original_text: original)
      row = make_task_row(folder: dir)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS,
                   @model.hive_model.idea_preview_text.length
    end
  end

  def test_idea_preview_roundtrip_open_then_any_key_dismisses
    with_tmp_dir do |dir|
      write_idea_md(dir, original_text: "Roundtrip idea")
      row = make_task_row(folder: dir)

      _, open_cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil open_cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal "Roundtrip idea", @model.hive_model.idea_preview_text

      _, dismiss_cmd = @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ "x".ord ]))

      assert_nil dismiss_cmd
      assert_equal :grid, @model.hive_model.mode
      assert_nil @model.hive_model.idea_preview_text
      assert_nil @model.hive_model.idea_preview_slug
      assert_empty @messages
    end
  end

  # ---- max_passes-hit REVIEW_STALE → open_review_stale_file ----

  def test_recover_review_stale_max_passes_opens_focal_escalations_file
    # Happy path: REVIEW_STALE pass=N (no reason attr), file exists.
    # The handler resolves <folder>/reviews/escalations-NN.md and
    # returns a SequenceCommand opening the editor against it.
    # Pure browse: no clear, no rerun, no follow-up dispatch.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      escalations = File.join(dir, "reviews", "escalations-04.md")
      File.write(escalations, "## High\n- [ ] real finding\n")

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "4" }, suggested_command: nil
      )
      seen_editor_invocation = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor", "--wait" ] }
      @model.define_singleton_method(:run_editor) do |argv, path|
        seen_editor_invocation = [ argv, path ]
        0
      end

      ran_clear = false
      with_run_quiet_stub(->(_argv) { ran_clear = true; [ 0, "", "" ] }) do
        _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        assert_kind_of Bubbletea::SequenceCommand, cmd
        assert_match(/opening reviews for stale-review in fake-editor/, @model.hive_model.flash)

        cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call
      end

      assert_equal [ [ "fake-editor", "--wait" ], escalations ], seen_editor_invocation
      refute ran_clear, "max_passes-hit browse must not clear the marker"
      assert_empty @messages, "browse must dispatch no follow-up message"
    end
  end

  def test_recover_review_stale_max_passes_picks_escalations_by_pass_attr_not_highest_nn_on_disk
    # The resolver's contract is: open the focal file recorded in the
    # marker's `pass=N` attr, NOT the highest-NN escalations file on
    # disk. This matters for tasks that hit REVIEW_STALE at pass=2,
    # got partially fixed (escalations-03.md, escalations-04.md
    # leftover from an interrupted re-run), but the operator-visible
    # marker still records pass=2. A future refactor that switched to
    # `Dir.glob.max` would silently break this contract — the test
    # locks it down.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "escalations-01.md"), "## pass-1 findings\n")
      File.write(File.join(dir, "reviews", "escalations-02.md"), "## pass-2 findings (the recorded pass)\n")
      File.write(File.join(dir, "reviews", "escalations-03.md"), "## pass-3 findings\n")
      File.write(File.join(dir, "reviews", "escalations-04.md"), "## pass-4 findings\n")

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "2" }, suggested_command: nil
      )
      seen_path = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        seen_path = path
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal File.join(dir, "reviews", "escalations-02.md"), seen_path,
                   "resolver must select by attrs[\"pass\"], NOT by highest-NN escalations-*.md on disk"
    end
  end

  def test_recover_review_stale_max_passes_falls_back_to_reviews_dir
    # Defensive corner: marker claims REVIEW_STALE pass=4 but no
    # pass-4 files exist on disk at all (corrupted state). The
    # path resolver falls back to the reviews/ directory so the
    # operator can browse whatever IS there.
    #
    # Setup uses an empty reviews/ directory (no reviewer files at
    # all) — this is the most robust shape for this test: previous
    # iterations relied on an older-pass `claude-ce-code-review-02.md`
    # to avoid tripping the incomplete-triage predicate, but if that
    # predicate's match pattern ever broadens, the test silently
    # inverts meaning. An empty dir can't fire the predicate
    # regardless of how its pattern evolves.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "4" }, suggested_command: nil
      )
      seen_path = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        seen_path = path
        0
      end

      _, new_model_or_cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      cmd = new_model_or_cmd
      assert_kind_of Bubbletea::SequenceCommand, cmd,
                     "missing escalations-NN.md but reviews/ exists → dir fallback, not refusal"
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal File.join(dir, "reviews"), seen_path,
                   "missing escalations-04.md must fall back to the reviews/ directory"
      # Differentiated flash: operator must know they're seeing the
      # dir, not the focal file, so they can't conflate older-pass
      # content with current-pass findings (ADV-4 in PR #66 review).
      assert_match(/focal escalations-04\.md missing/, @model.hive_model.flash,
                   "dir-fallback flash must explicitly say the focal file is missing")
    end
  end

  def test_recover_review_stale_max_passes_refuses_when_neither_file_nor_dir_exists
    # Defensive: folder exists but has no reviews subtree at all.
    # Handler flashes refusal, returns no takeover command.
    with_tmp_dir do |dir|
      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "4" }, suggested_command: nil
      )

      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      assert_nil cmd
      assert_match(/no review files for stale-review/, @model.hive_model.flash.to_s)
    end
  end

  def test_recover_review_stale_max_passes_refuses_when_pass_attr_missing
    # Legacy/malformed marker: REVIEW_STALE with no `pass` attr.
    # Path resolver returns "" because we can't build the focal path
    # without a pass number; refusal flash fires.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: {}, suggested_command: nil
      )

      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      assert_nil cmd
      assert_match(/no review files for stale-review/, @model.hive_model.flash.to_s)
    end
  end

  def test_recover_review_stale_max_passes_with_malformed_pass_falls_back_to_dir
    # Edge: `pass` is non-integer (legacy/corrupted). Integer() raises
    # ArgumentError; rescue falls back to the reviews/ directory when
    # it exists. Defensive: a bad marker can't crash the renderer.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "abc" }, suggested_command: nil
      )
      seen_path = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        seen_path = path
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal File.join(dir, "reviews"), seen_path
    end
  end

  def test_recover_review_stale_max_passes_rejects_non_positive_pass_values
    # Defensive: pass < 1 is rejected explicitly (mirrors the existing
    # `retryable_incomplete_triage_pass?` "valid pass" convention).
    # Negative values would build malformed filenames like
    # `escalations--1.md`; zero is not a legitimate runner output.
    # Both cases must refuse with the "no review files" flash, NOT
    # fall through to the integer-formatted-but-nonsense filename.
    %w[-1 -4 0 +0].each do |bad_pass|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, "reviews"))
        # Empty reviews dir — the test pins the pass-rejection path,
        # not the dir-fallback. We're asserting refusal.
        row = make_task_row(
          action_key: "recover_review", slug: "stale-review", stage: "6-review",
          folder: dir, marker: "review_stale", attrs: { "pass" => bad_pass }, suggested_command: nil
        )
        @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
        @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

        _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        # `pass < 1` short-circuits the resolver to "", so the dir
        # fallback never fires. Combined with the empty reviews/
        # directory we end up with the refusal flash and nil cmd.
        if bad_pass.start_with?("-") || bad_pass.start_with?("+0")
          # Non-positive values short-circuit BEFORE the reviews_dir
          # fallback; refusal flash + nil cmd.
          assert_nil cmd, "non-positive pass=#{bad_pass} must short-circuit before dir-fallback"
        end
      end
    end
  end

  def test_recover_review_stale_max_passes_rejects_path_traversal_pass_payload
    # Security: the strict-base-10 `Integer(pass, 10)` parse is the
    # load-bearing defense against `pass="../../etc/passwd"` (which
    # `pass.to_i` would silently coerce to 0). Pinning this test
    # protects the defense against a future refactor that "simplifies"
    # the parse without realizing it's a security boundary.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale",
        attrs: { "pass" => "../../etc/passwd" }, suggested_command: nil
      )
      seen_path = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        seen_path = path
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      # Path-traversal payload must NOT resolve to anything outside
      # the task folder. The strict parse rejects it (ArgumentError),
      # the rescue falls back to `<folder>/reviews/` (which is
      # inside the task folder by construction).
      assert_equal File.join(dir, "reviews"), seen_path,
                   "path-traversal pass attr must be rejected by Integer(pass, 10) and fall back to local reviews/ dir"
      refute_includes seen_path, "..", "the resolved path must not contain '..' traversal"
      refute_includes seen_path, "/etc/", "the resolved path must not escape to /etc"
    end
  end

  def test_recover_review_stale_max_passes_does_not_call_markers_set_or_dispatch
    # R3 contract: open_review_stale_file is pure browse. No
    # Hive::Markers.set call, no follow-up message dispatch. The
    # marker stays as the operator saw it; clearing remains a
    # deliberate `hive markers clear` round-trip.
    #
    # Both halves of the contract are tightened: the no-Markers.set
    # half is enforced by overriding Hive::Markers.set to raise (so
    # any call surfaces as a test failure with a precise message);
    # the no-follow-up-dispatch half is enforced by asserting an
    # empty `@messages`. Previously this test only checked the
    # second half — a future regression that silently called
    # Markers.set on this path would have passed.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "escalations-04.md"), "## High\n")

      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "4" }, suggested_command: nil
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      original_set = Hive::Markers.singleton_class.instance_method(:set)
      markers_set_called = false
      Hive::Markers.define_singleton_method(:set) do |*args, **kwargs|
        markers_set_called = true
        flunk "Hive::Markers.set must not be called from open_review_stale_file (pure browse contract)"
      end

      begin
        _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call
      ensure
        Hive::Markers.singleton_class.define_method(:set, original_set)
      end

      refute markers_set_called,
             "max_passes-hit browse must not call Hive::Markers.set"
      assert_empty @messages,
        "max_passes-hit browse must not dispatch InputEditorExited or any other follow-up"
    end
  end

  # ---- Plan-stage auto-continue (3-plan) ----

  def test_open_input_editor_advances_to_develop_when_plan_unchanged
    # User opens plan.md, saves without changes → auto-advance to
    # `hive develop`. The marker on disk is still `<!-- WAITING -->`
    # (the agent thinks it has questions); the user is overriding by
    # saving without editing.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, <<~MD)
        # Plan
        Some content the agent wrote.
        <!-- WAITING -->
      MD
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      # Editor is a no-op: opens, returns 0, file untouched (real
      # File.mtime / File.read drive the comparison).
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length,
        "unchanged plan must dispatch [InputEditorExited, DispatchCommand for develop]"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_kind_of Hive::Tui::Messages::DispatchCommand, @messages[1]
      assert_equal "develop", @messages[1].verb
      assert_equal(
        [ "hive", "develop", "some-slug", "--from", "3-plan" ],
        @messages[1].argv
      )
    end
  end

  def test_open_input_editor_revises_plan_when_user_added_feedback
    # User adds inline feedback in the plan; auto-continue dispatches
    # the row's existing `hive plan ... --from 3-plan` so the agent
    # reads the comment and revises.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nOriginal content.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      # Stub editor: writes a comment line into the plan, simulating
      # the user's `:wq` after typing.
      @model.define_singleton_method(:run_editor) do |_argv, path|
        File.write(path, "# Plan\nOriginal content.\nUser feedback here.\n<!-- WAITING -->\n")
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length,
        "edited plan must dispatch [InputEditorExited, DispatchCommand for plan re-run]"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_equal true, @messages[0].changed
      assert_kind_of Hive::Tui::Messages::DispatchCommand, @messages[1]
      assert_equal "plan", @messages[1].verb
      assert_equal(
        [ "hive", "plan", "some-slug", "--from", "3-plan" ],
        @messages[1].argv
      )
    end
  end

  def test_open_input_editor_no_plan_action_when_marker_changed_to_complete
    # Race: another actor advanced the plan to `<!-- COMPLETE -->`
    # while the editor was open. Even if the user added content, do
    # not auto-anything — surface a suppression flash so the user
    # knows the captured row was stale.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nFinalised by another actor.\n<!-- COMPLETE -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        marker: "waiting", # row attr is stale; production reads marker from disk
        suggested_command: "hive plan some-slug --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        File.write(path, "# Plan\nFinalised by another actor.\nuser-added.\n<!-- COMPLETE -->\n")
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/marker changed during edit/, @messages[1].text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
        "marker race must NOT auto-dispatch")
    end
  end

  def test_open_input_editor_plan_stays_silent_when_editor_aborted
    # SIGINT during edit on a plan row: take no auto action either way.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nContent.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 130 } # SIGINT

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages.first
      assert_equal 130, @messages.first.exit_code
    end
  end

  def test_open_input_editor_plan_with_malformed_suggested_command_falls_back_on_revise
    # User added feedback (revise path) but suggested_command is
    # malformed. Suppression flash keeps the user informed; no
    # DispatchCommand fires.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nOriginal.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        # Unbalanced quote → Shellwords.split raises ArgumentError.
        suggested_command: %q(hive plan slug --note 'unclosed)
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        File.write(path, "# Plan\nOriginal.\nUser added.\n<!-- WAITING -->\n")
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_equal 2, @messages.length
      assert_kind_of Hive::Tui::Messages::InputEditorExited, @messages[0]
      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/malformed suggested command/, @messages[1].text)
    end
  end

  def test_open_input_editor_plan_advance_falls_back_when_command_is_not_hive_plan
    # `develop_command_from_plan` requires the suggested_command to
    # start with `hive plan`. If the row is misconfigured (e.g. row
    # builder bug), surface a suppression flash instead of crashing.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nUntouched.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        # Missing `plan` verb — develop_command_from_plan must refuse.
        suggested_command: "hive develop some-slug --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      assert_kind_of Hive::Tui::Messages::Flash, @messages[1]
      assert_match(/couldn't build develop command/, @messages[1].text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
        "misconfigured suggested_command must NOT spawn anything")
    end
  end

  def test_open_input_editor_plan_advance_finalizes_marker_before_dispatching_develop
    # Regression: `hive develop --from 3-plan` refuses to advance
    # while the marker is `:waiting`. The TUI's `:advance_to_develop`
    # outcome must flip the marker from `:waiting` to `:complete`
    # BEFORE dispatching `hive develop`, otherwise the background
    # subprocess fails silently and the task stays stuck. Diagnosed
    # via the `i-want-to-be-able-260507-7682` /
    # `now-we-run-claude-codex-260508-3b8f` bug report.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nUntouched.\n<!-- WAITING -->\n")
      pre_marker = Hive::Markers.current(plan_md)
      assert_equal :waiting, pre_marker.name, "preconditions: marker starts as :waiting"

      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --project demo --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      # Marker must be `:complete` on disk after the auto-advance.
      post_marker = Hive::Markers.current(plan_md)
      assert_equal :complete, post_marker.name,
                   "marker must be flipped to :complete before hive develop is dispatched"

      # DispatchCommand for `hive develop` must be in the message
      # stream (in addition to the InputEditorExited).
      dispatch = @messages.find { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) }
      refute_nil dispatch, "expected a DispatchCommand for hive develop"
      assert_equal "develop", dispatch.verb
      assert_includes dispatch.argv, "develop"
      assert_includes dispatch.argv, "some-slug"
    end
  end

  def test_open_input_editor_plan_advance_leaves_marker_waiting_when_command_is_malformed
    # Post-review P2 #2: if the suggested_command can't be parsed
    # into a `hive develop ...` argv, the marker MUST stay :waiting
    # (no dispatch + no marker change). The previous order flipped
    # the marker eagerly, which would leave the plan looking
    # "approved" while no execute stage ever started.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nUntouched.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive develop wrong-verb --from 3-plan" # not `hive plan ...`
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      flash = @messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
      refute_nil flash
      assert_match(/couldn't build develop command/, flash.text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
             "no DispatchCommand on malformed command")

      post_marker = Hive::Markers.current(plan_md)
      assert_equal :waiting, post_marker.name,
                   "marker must stay :waiting when the dispatch can't be built — " \
                   "flipping to :complete with no dispatch would leave the plan " \
                   "in a 'looks approved but execute never started' limbo"
    end
  end

  def test_open_input_editor_plan_advance_refuses_when_marker_drifted_during_edit
    # Post-review P2 #1: between `plan_outcome`'s
    # `marker_still_open_for_input?` check (run when the editor
    # closes) and the `finalize_plan_marker` write, a concurrent
    # actor could have advanced the marker. Without the CAS in
    # finalize_plan_marker, Hive::Markers.set would silently
    # overwrite the newer marker. With the CAS, we raise
    # MarkerRaceError and surface a suppression flash instead.
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nUntouched.\n<!-- WAITING -->\n")
      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --project demo --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) do |_argv, path|
        # Simulate a concurrent actor advancing the marker WHILE
        # the editor was open. By the time the editor exits, the
        # marker on disk is no longer :waiting.
        Hive::Markers.set(path, :agent_working)
        0
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      flash = @messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
      refute_nil flash, "expected a flash when marker drifted"
      # The `marker_still_open_for_input?` early check fires first
      # (`plan_outcome` returns :marker_changed before reaching
      # `dispatch_develop_for`), so the surface message is the
      # "marker changed during edit" flash — same observable
      # outcome as the race-during-finalize would produce. Pin both
      # — either is acceptable so long as no DispatchCommand fires
      # and the marker is not forcibly overwritten back to :complete.
      assert(flash.text =~ /marker changed during edit/ ||
             flash.text =~ /plan marker changed during edit/,
             "expected marker-race flash, got: #{flash.text.inspect}")
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
             "no DispatchCommand may be emitted on marker race")

      post_marker = Hive::Markers.current(plan_md)
      refute_equal :complete, post_marker.name,
                   "marker must NOT be overwritten by the TUI's :complete write when the " \
                   "marker had drifted to a different state during the edit (caught by " \
                   "the compare-and-set in finalize_plan_marker)"
    end
  end

  def test_open_input_editor_plan_advance_falls_back_when_marker_write_fails
    # When the marker flip fails (e.g., parent dir gone, perms),
    # surface a suppression flash and DO NOT dispatch hive develop —
    # dispatching against a still-`:waiting` marker would just hit
    # the StageAction refusal silently in the background. Drive the
    # failure by stubbing `finalize_plan_marker` to raise, which is
    # the same surface the rescue would see for any real
    # SystemCallError/IOError (read-only dir, ENOSPC, ENOENT, etc.)
    # without depending on the host's chmod semantics or atomic-
    # rename behavior (Hive::Markers.set writes via temp+rename,
    # which is robust to a read-only file).
    with_tmp_dir do |dir|
      plan_md = File.join(dir, "plan.md")
      File.write(plan_md, "# Plan\nUntouched.\n<!-- WAITING -->\n")

      row = make_task_row(
        stage: "3-plan",
        state_file: plan_md,
        suggested_command: "hive plan some-slug --project demo --from 3-plan"
      )
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |_argv, _path| 0 }
      @model.define_singleton_method(:finalize_plan_marker) do |_row|
        raise Errno::EACCES, "Permission denied @ apply2files - #{plan_md}"
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      flash = @messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
      refute_nil flash, "expected a suppression flash on marker-write failure"
      assert_match(/couldn't finalize plan marker/, flash.text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
             "no DispatchCommand may be emitted when the marker flip failed")
    end
  end

  def test_open_input_editor_with_missing_state_file_flashes_without_command
    row = make_task_row(state_file: nil)
    _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))

    assert_nil cmd
    assert_match(/no input file/, @model.hive_model.flash)
  end

  def test_open_input_editor_with_invalid_editor_command_flashes_without_command
    row = make_task_row

    with_editor_env(visual: "\"", editor: nil) do
      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))

      assert_nil cmd
      assert_match(/editor command invalid/, @model.hive_model.flash)
    end
  end

  def test_run_editor_translates_missing_editor_to_command_not_found_exit
    missing_editor = "hive-test-missing-editor-#{Process.pid}-#{object_id}"

    exit_code = @model.send(:run_editor, [ missing_editor ], "/tmp/missing-state.md")

    assert_equal Hive::Tui::Subprocess::COMMAND_NOT_FOUND_EXIT, exit_code
  end

  def test_open_input_editor_targets_review_waiting_escalations_file
    Dir.mktmpdir("hive-review-waiting") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-02.md"), "## High\n- [ ] real finding\n")
      escalations = File.join(reviews, "escalations-02.md")
      File.write(escalations, "## Round 1\n\n### Q1. What should hive do?\n### A1.\n")
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "2", "escalations" => "1" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal(
        [ [ "fake-editor" ], escalations ],
        seen_editor_invocation
      )
    end
  end

  def test_open_input_editor_targets_escalations_file_when_multiple_review_waiting_sources
    Dir.mktmpdir("hive-review-waiting") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-02.md"), "## High\n- [ ] claude finding\n")
      File.write(File.join(reviews, "codex-02.md"), "## High\n- [ ] codex finding\n")
      escalations = File.join(reviews, "escalations-02.md")
      File.write(escalations, "## Round 1\n\n### Q1. What should hive do?\n### A1.\n")
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "2", "escalations" => "2" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal [ [ "fake-editor" ], escalations ], seen_editor_invocation
    end
  end

  def test_open_input_editor_targets_errors_file_for_reviewer_partial_failure
    Dir.mktmpdir("hive-review-partial-failure") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      errors = File.join(reviews, "errors-02.md")
      File.write(errors, "# Reviewer infra errors\n")
      File.write(File.join(reviews, "escalations-02.md"), "## Round 1\n\n### Q1. What should hive do?\n### A1.\n")
      row = make_task_row(
        stage: "5-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "2", "reason" => "reviewer_partial_failure" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal [ [ "fake-editor" ], errors ], seen_editor_invocation
    end
  end

  def test_open_input_editor_falls_back_to_reviews_dir_when_multiple_review_sources_have_no_escalations_file
    Dir.mktmpdir("hive-review-waiting") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-02.md"), "## High\n- [ ] claude finding\n")
      File.write(File.join(reviews, "codex-02.md"), "## High\n- [ ] codex finding\n")
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "2", "escalations" => "2" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal [ [ "fake-editor" ], reviews ], seen_editor_invocation
    end
  end

  def test_open_input_editor_targets_fix_guardrail_file_for_fix_guardrail_review_waiting
    # Regression: PR-A originally opened the reviews/ directory for
    # `reason=fix_guardrail` rows. That broke U6's auto-continue
    # because `read_checkbox_state` on a directory rescues
    # `Errno::EISDIR` to `[]`, so the before/after delta was always
    # empty → `:silent` outcome → no dispatch. Fix: route Enter to
    # the focal file directly so the checkbox-set snapshot can
    # observe the user's `[x]` ticks.
    Dir.mktmpdir("hive-review-waiting") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "claude-03.md"), "## High\n- [x] original fix\n")
      guardrail_path = File.join(reviews, "fix-guardrail-03.md")
      File.write(guardrail_path, "- [ ] shell_pipe_to_interpreter\n")
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "3", "reason" => "fix_guardrail" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal [ [ "fake-editor" ], guardrail_path ], seen_editor_invocation,
                   "fix_guardrail row must open the focal fix-guardrail-NN.md file, NOT the reviews/ directory"
    end
  end

  def test_open_input_editor_falls_back_to_reviews_dir_when_fix_guardrail_file_missing
    # Defensive: if the file is missing (user deleted it, runner
    # never wrote it, etc.) fall back to the reviews/ directory so
    # the user can at least navigate to find the right state. The
    # checkbox-set delta still returns false in this case so U6
    # auto-continue won't fire — that's correct (no file to approve).
    Dir.mktmpdir("hive-review-waiting") do |folder|
      reviews = File.join(folder, "reviews")
      FileUtils.mkdir_p(reviews)
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "3", "reason" => "fix_guardrail" }
      )

      seen_editor_invocation = capture_input_editor_invocation(row)

      assert_equal [ [ "fake-editor" ], reviews ], seen_editor_invocation,
                   "fix_guardrail row with no focal file falls back to reviews/"
    end
  end

  # --- U6 auto-continue unit coverage (ce-review P1 #9) ---------------
  #
  # The new TUI auto-continue path for 6-review needs_input rows
  # gained four private methods that PR-A originally shipped without
  # direct tests. The two P0 bugs caught in /ce-review (Flash kwarg
  # crash + reviews-dir-as-editor-path silencing every dispatch) would
  # have been caught instantly by happy-path coverage. These tests
  # exercise each new method directly.

  def make_review_waiting_row(folder, pass:, reason: "fix_guardrail")
    attrs = { "pass" => pass.to_s }
    attrs["reason"] = reason if reason
    make_task_row(
      stage: "6-review",
      folder: folder,
      state_file: File.join(folder, "task.md"),
      marker: "review_waiting",
      attrs: attrs,
      suggested_command: "hive run --folder #{folder}"
    )
  end

  def test_read_checkbox_state_returns_checked_unchecked_counts
    Dir.mktmpdir("u6-read-checkbox") do |dir|
      path = File.join(dir, "fix-guardrail-04.md")
      File.write(path, <<~MD)
        # Fix-guardrail findings for pass 04

        - [ ] dotenv_edit: .env.production
        - [x] permission_change: bin/script
        - [X] dependency_lockfile_change: Gemfile.lock
      MD
      counts = @model.send(:read_checkbox_state, path)
      assert_equal({ checked: 2, unchecked: 1 }, counts)
    end
  end

  def test_read_checkbox_state_set_equivalence_ignores_line_order
    # pr-review-toolkit round-5 #5: a user who cuts a `[x]` line and
    # pastes it elsewhere should not trigger :rerun_review — the
    # `[x]` count is unchanged. The order-sensitive Array shape we
    # had before tripped on this; the counts-Hash form is set-
    # equivalent.
    Dir.mktmpdir("u6-read-checkbox") do |dir|
      a_path = File.join(dir, "a.md")
      b_path = File.join(dir, "b.md")
      File.write(a_path, "- [x] one\n- [ ] two\n- [x] three\n")
      File.write(b_path, "- [ ] two\n- [x] three\n- [x] one\n")
      assert_equal @model.send(:read_checkbox_state, a_path),
                   @model.send(:read_checkbox_state, b_path),
                   "checkbox-counts must be order-insensitive"
    end
  end

  def test_read_checkbox_state_returns_zero_counts_for_directory
    # The original PR-A bug: editor path was a directory; rescue
    # Errno::EISDIR returns zero counts silently, letting :silent
    # fire on every fix_guardrail edit. The structural fix is to
    # NOT pass a directory (see input_editor_path tests above);
    # this rescue is defense in depth.
    Dir.mktmpdir("u6-read-checkbox-dir") do |dir|
      counts = @model.send(:read_checkbox_state, dir)
      assert_equal({ checked: 0, unchecked: 0 }, counts)
    end
  end

  def test_read_checkbox_state_returns_zero_counts_for_missing_file
    counts = @model.send(:read_checkbox_state, "/nonexistent/path/fix-guardrail-04.md")
    assert_equal({ checked: 0, unchecked: 0 }, counts)
  end

  def test_review_outcome_silent_when_checkbox_set_unchanged
    # Bare `:wq` ticks mtime but does not change the checkbox set —
    # critical U6 invariant: avoid no-op runner round-trips.
    Dir.mktmpdir("u6-review-outcome") do |folder|
      row = make_review_waiting_row(folder, pass: 4)
      outcome = @model.send(:review_outcome, row, File.join(folder, "reviews/escalations-04.md"), false, false)
      assert_equal :silent, outcome
    end
  end

  def test_review_outcome_empty_command_when_suggested_command_blank
    Dir.mktmpdir("u6-review-outcome") do |folder|
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: File.join(folder, "task.md"),
        marker: "review_waiting",
        attrs: { "pass" => "4", "reason" => "fix_guardrail" },
        suggested_command: ""
      )
      outcome = @model.send(:review_outcome, row, File.join(folder, "reviews/fix-guardrail-04.md"), true, false)
      assert_equal :empty_command, outcome
    end
  end

  def test_review_outcome_marker_changed_when_marker_drifted
    # Race: editor open with marker :review_waiting; concurrent
    # `hive run` advances marker to :agent_working. On save we must
    # NOT re-dispatch — the second action is mid-flight.
    Dir.mktmpdir("u6-review-outcome") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- AGENT_WORKING phase=fix pass=4 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      outcome = @model.send(:review_outcome, row, File.join(folder, "reviews/fix-guardrail-04.md"), true, false)
      assert_equal :marker_changed, outcome
    end
  end

  def test_review_outcome_rerun_review_on_checkbox_change_and_marker_intact
    Dir.mktmpdir("u6-review-outcome") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING reason=fix_guardrail pass=4 matches=2 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      outcome = @model.send(:review_outcome, row, File.join(folder, "reviews/fix-guardrail-04.md"), true, false)
      assert_equal :rerun_review, outcome
    end
  end

  def test_review_outcome_rerun_review_on_escalation_answer_content_change
    Dir.mktmpdir("u6-review-outcome") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING escalations=1 pass=4 -->\n")
      row = make_review_waiting_row(folder, pass: 4, reason: nil)
      outcome = @model.send(:review_outcome, row, File.join(folder, "reviews/escalations-04.md"), false, true)
      assert_equal :rerun_review, outcome
    end
  end

  def test_review_marker_state_open_for_matching_review_waiting
    Dir.mktmpdir("u6-marker-check") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING reason=fix_guardrail pass=4 matches=2 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      assert_equal :open, @model.send(:review_marker_state, row)
    end
  end

  def test_review_marker_state_drifted_for_agent_working
    Dir.mktmpdir("u6-marker-check") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- AGENT_WORKING phase=fix pass=4 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      assert_equal :drifted, @model.send(:review_marker_state, row)
    end
  end

  # ce-review round-3 P2 #7 — a stale editor session for pass 4 must
  # NOT dispatch when a concurrent process advanced the task to pass
  # 5, or to a different REVIEW_WAITING reason family.
  def test_review_marker_state_drifted_when_marker_pass_advanced
    Dir.mktmpdir("u6-marker-check") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING reason=fix_guardrail pass=5 matches=2 -->\n")
      stale_row = make_review_waiting_row(folder, pass: 4) # editor opened on pass 4
      assert_equal :drifted, @model.send(:review_marker_state, stale_row),
                   "marker advanced to pass 5; stale pass-4 row must drift"
    end
  end

  def test_review_marker_state_drifted_when_marker_reason_drifted
    Dir.mktmpdir("u6-marker-check") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING escalations=3 pass=4 -->\n")
      stale_row = make_review_waiting_row(folder, pass: 4, reason: "fix_guardrail")
      assert_equal :drifted, @model.send(:review_marker_state, stale_row),
                   "row was for fix_guardrail; marker drifted to escalations"
    end
  end

  # pr-review-toolkit round-5 H3 + pr-test-analyzer #6: distinguish
  # "marker drifted" from "couldn't read marker" so the user-facing
  # flash matches the real cause.
  def test_review_marker_state_unreadable_when_state_file_unreadable
    Dir.mktmpdir("u6-marker-check") do |folder|
      # Pass a directory where the state_file is expected — reading it
      # raises Errno::EISDIR, which the rescue catches.
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: folder, # directory, not a file
        marker: "review_waiting",
        attrs: { "pass" => "4", "reason" => "fix_guardrail" }
      )
      assert_equal :unreadable, @model.send(:review_marker_state, row),
                   "directory-as-state-file must return :unreadable, not :drifted"
    end
  end

  # pr-review-toolkit round-5 pr-test-analyzer #5 — positive test for
  # the rescue path in `dispatch_rerun_review_for`. A regression that
  # widens the rescue scope or drops the suppression flash would not
  # be caught without exercising the malformed-command branch.
  def test_dispatch_rerun_review_for_malformed_command_emits_suppression_flash
    folder = "/tmp/hive/test-malformed"
    row = make_task_row(
      stage: "6-review",
      folder: folder,
      state_file: File.join(folder, "task.md"),
      marker: "review_waiting",
      attrs: { "pass" => "4", "reason" => "fix_guardrail" },
      slug: "test-malformed",
      # Unmatched quote → Shellwords.split raises ArgumentError.
      suggested_command: "hive run --folder #{folder} 'unterminated"
    )
    exited = Hive::Tui::Messages::InputEditorExited.new(
      slug: row.slug, exit_code: 0, changed: true
    )

    messages = @model.send(:dispatch_rerun_review_for, row, exited)

    assert_equal 2, messages.size, "rescue path emits [exited, suppression_flash] — no dispatch"
    assert_same exited, messages[0]
    assert_kind_of Hive::Tui::Messages::Flash, messages[1]
    assert_match(/malformed suggested command/, messages[1].text)
    assert(messages.none? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
           "no DispatchCommand may be emitted when the command can't be parsed")
  end

  # pr-review-toolkit round-5 pr-test-analyzer #7 — integration test
  # through `input_editor_exit_messages` driving the full
  # `auto_continue_outcome → review_outcome → dispatch_rerun_review_for`
  # path for the happy 6-review case. A regression that adds a new
  # `:silent` early-return in `auto_continue_outcome` before reaching
  # `review_outcome` would not be caught by the unit tests above.
  def test_input_editor_exit_messages_6_review_dispatches_review_verb_on_checkbox_change
    Dir.mktmpdir("u6-exit-integration") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING reason=fix_guardrail pass=4 matches=2 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      messages = @model.send(
        :input_editor_exit_messages,
        row,
        File.join(folder, "reviews/fix-guardrail-04.md"),
        0,        # exit_code
        true,     # changed (mtime)
        false,    # content_changed (irrelevant for 6-review)
        true      # checkboxes_changed — the load-bearing signal
      )

      assert_equal 3, messages.size, "happy path: [InputEditorExited, Flash, DispatchCommand]"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, messages[0]
      assert_kind_of Hive::Tui::Messages::Flash, messages[1]
      assert_match(/approved/, messages[1].text)
      assert_kind_of Hive::Tui::Messages::DispatchCommand, messages[2]
    end
  end

  def test_input_editor_exit_messages_6_review_silent_on_no_checkbox_change
    Dir.mktmpdir("u6-exit-integration") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING reason=fix_guardrail pass=4 matches=2 -->\n")
      row = make_review_waiting_row(folder, pass: 4)
      messages = @model.send(
        :input_editor_exit_messages,
        row, File.join(folder, "reviews/fix-guardrail-04.md"),
        0, true, false,
        false # checkboxes unchanged — bare :wq
      )
      assert_equal 1, messages.size, "bare :wq must emit only [InputEditorExited], no dispatch"
      assert_kind_of Hive::Tui::Messages::InputEditorExited, messages[0]
    end
  end

  def test_input_editor_exit_messages_5_review_dispatches_on_escalation_answer_edit
    Dir.mktmpdir("u6-exit-integration") do |folder|
      task_md = File.join(folder, "task.md")
      File.write(task_md, "<!-- REVIEW_WAITING escalations=1 pass=4 -->\n")
      row = make_review_waiting_row(folder, pass: 4, reason: nil)
      messages = @model.send(
        :input_editor_exit_messages,
        row, File.join(folder, "reviews/escalations-04.md"),
        0, true,
        true,  # content changed in Q&A escalation file
        false  # no checkbox changes needed for Q&A answers
      )

      assert_equal 3, messages.size
      assert_kind_of Hive::Tui::Messages::Flash, messages[1]
      assert_kind_of Hive::Tui::Messages::DispatchCommand, messages[2]
    end
  end

  def test_input_editor_exit_messages_5_review_marker_unreadable_surfaces_distinct_flash
    Dir.mktmpdir("u6-exit-integration") do |folder|
      # state_file points at the folder (a directory) — read fails
      # with Errno::EISDIR → review_marker_state returns :unreadable
      # → outcome is :marker_unreadable (distinct from :marker_changed).
      row = make_task_row(
        stage: "6-review",
        folder: folder,
        state_file: folder,
        marker: "review_waiting",
        attrs: { "pass" => "4", "reason" => "fix_guardrail" },
        suggested_command: "hive run --folder #{folder}"
      )
      messages = @model.send(
        :input_editor_exit_messages,
        row, File.join(folder, "reviews/fix-guardrail-04.md"),
        0, true, false, true
      )
      assert_equal 2, messages.size, ":marker_unreadable emits [Exited, suppression_flash]"
      assert_kind_of Hive::Tui::Messages::Flash, messages[1]
      assert_match(/couldn't read marker/, messages[1].text,
                   "flash must name the actual cause — marker unreadable, not just 'changed'")
      refute_match(/marker changed/, messages[1].text)
    end
  end

  def test_dispatch_rerun_review_for_emits_exited_flash_dispatch_triple
    # The original P0: Flash.new with unknown :source kwarg raised
    # ArgumentError silently caught by the local rescue, routing to a
    # 'malformed suggested command' flash instead of dispatching.
    # This test pins the corrected message shape.
    folder = "/tmp/hive/test-slug"
    row = make_task_row(
      stage: "6-review",
      folder: folder,
      state_file: File.join(folder, "task.md"),
      marker: "review_waiting",
      attrs: { "pass" => "4", "reason" => "fix_guardrail" },
      slug: "test-slug",
      suggested_command: "hive run --folder #{folder}"
    )
    exited = Hive::Tui::Messages::InputEditorExited.new(
      slug: row.slug, exit_code: 0, changed: true
    )

    messages = @model.send(:dispatch_rerun_review_for, row, exited)

    assert_equal 3, messages.size, "expected [exited, flash, dispatch]"
    assert_same exited, messages[0]
    assert_kind_of Hive::Tui::Messages::Flash, messages[1]
    assert_match(/approved/, messages[1].text)
    assert_match(/test-slug/, messages[1].text)
    refute_match(/malformed/, messages[1].text,
                 "the suppression-flash branch must NOT fire on the happy path")
    assert_kind_of Hive::Tui::Messages::DispatchCommand, messages[2]
  end

  def capture_input_editor_invocation(row)
    seen_editor_invocation = nil
    @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
    @model.define_singleton_method(:file_mtime) { |_path| 0.0 }
    @model.define_singleton_method(:run_editor) do |argv, path|
      seen_editor_invocation = [ argv, path ]
      0
    end

    _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
    cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call
    seen_editor_invocation
  end

  # ---- Late-binding dispatch (so App.run_charm can wire runner.method(:send)) ----

  def test_dispatch_setter_replaces_callable
    new_dispatch = ->(_m) { }
    @model.dispatch = new_dispatch
    # The replacement dispatch is now what the background reaper would
    # dispatch SubprocessExited through. Smoke check: the call doesn't
    # raise (returns nil cmd just like any DispatchCommand).
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo" ], verb: nil)
    _, cmd = @model.update(msg)
    assert_nil cmd
  end

  # ---- Side-effect handlers must not propagate file-system exceptions ----
  #
  # The TUI runs inside `Bubbletea::Runner.run`; an unhandled exception
  # from `BubbleModel#update` unwinds out of the runner and tears down
  # the alt-screen mid-frame, leaving the user's terminal in a corrupt
  # state. Every side-effect handler that does I/O must therefore rescue
  # the predictable failure modes and surface them as a flash, never
  # raise.
  #
  # The dogfood-found regression: pressing Enter on an `error`-state
  # row whose task hadn't run any agent yet (logs/ dir empty) made
  # `LogTail::FileResolver.latest` raise `Hive::NoLogFiles`, which
  # wasn't in `open_log_tail`'s rescue list, killing the TUI.

  # ---- Auto-heal: kill-class error markers (SIGINT/SIGKILL/SIGTERM) ----
  #
  # When `hive pr` (or any takeover) gets killed mid-spawn — pgroup
  # forwards SIGTERM, the agent writes `:error reason=exit_code
  # exit_code=143`, and the task folder is left intact — the file
  # state IS recoverable but the marker says "Error". Auto-heal
  # clears those markers in the background so the TUI doesn't strand
  # interrupted tasks in a stuck "Error" classification the user has
  # to manually escape from.

  def make_error_row(slug:, folder:, exit_code:, reason: "exit_code")
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo", stage: "6-review", slug: slug, folder: folder,
      state_file: nil, marker: "error", attrs: { "reason" => reason, "exit_code" => exit_code.to_s },
      mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "error", action_label: "Error", suggested_command: nil, next_action: nil,
      diagnostic: nil
    )
  end

  def stub_heal_capture(model)
    captured = []
    model.define_singleton_method(:spawn_heal_thread) { |row| captured << row.folder }
    captured
  end

  def snapshot_with(rows)
    project = Hive::Tui::Snapshot::ProjectView.new(
      name: "demo", path: "/x", hive_state_path: "/x/.hive-state",
      error: nil, rows: rows.freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ project ])
  end

  def test_snapshot_with_sigterm_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "killed", folder: "/x/.hive-state/stages/6-review/killed", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/6-review/killed" ], captured,
      "sigterm-killed task must trigger one heal"
  end

  def test_snapshot_with_sigint_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "ctrlc", folder: "/x/.hive-state/stages/4-execute/ctrlc", exit_code: 130) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/4-execute/ctrlc" ], captured
  end

  def test_snapshot_with_sigkill_error_triggers_heal
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "killed9", folder: "/x/.hive-state/stages/4-execute/killed9", exit_code: 137) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/.hive-state/stages/4-execute/killed9" ], captured
  end

  def test_snapshot_with_real_failure_does_not_heal
    # exit_code=1 is a normal program exit, not a signal kill — the
    # agent decided to fail. Auto-heal MUST NOT clear these; the
    # error reflects a real condition the user needs to inspect.
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "real-fail", folder: "/x/y", exit_code: 1) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_empty captured, "exit_code=1 is a real failure, must not auto-heal"
  end

  def test_snapshot_with_non_exit_code_error_does_not_heal
    # `:error reason=timeout` or `:error reason=secret_in_pr_body`
    # are real, structured errors — clearing them silently would
    # mask actual problems.
    captured = stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "timeout", folder: "/x/y", exit_code: nil, reason: "timeout") ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_empty captured
  end

  def test_snapshot_with_multiple_kill_class_rows_triggers_heal_for_each
    captured = stub_heal_capture(@model)
    snap = snapshot_with([
      make_error_row(slug: "a", folder: "/x/.hive-state/stages/6-review/a", exit_code: 143),
      make_error_row(slug: "b", folder: "/x/.hive-state/stages/4-execute/b", exit_code: 137),
      make_error_row(slug: "c", folder: "/x/.hive-state/stages/3-plan/c", exit_code: 130)
    ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal(
      [ "/x/.hive-state/stages/3-plan/c",
        "/x/.hive-state/stages/4-execute/b",
        "/x/.hive-state/stages/6-review/a" ],
      captured.sort,
      "every kill-class row in the snapshot must trigger its own heal — not just the first"
    )
  end

  def test_snapshot_mixing_kill_class_and_real_failures_only_heals_kill_class
    captured = stub_heal_capture(@model)
    snap = snapshot_with([
      make_error_row(slug: "killed", folder: "/x/k", exit_code: 143),  # SIGTERM, heal
      make_error_row(slug: "failed", folder: "/x/f", exit_code: 1),    # real failure, skip
      make_error_row(slug: "timed",  folder: "/x/t", exit_code: nil, reason: "timeout") # skip
    ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal [ "/x/k" ], captured,
      "only kill-class signals heal; real failures and timeouts must reach the user untouched"
  end

  def test_heal_dedup_only_fires_once_per_folder
    captured = stub_heal_capture(@model)
    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/6-review/killed", exit_code: 143)
    snap = snapshot_with([ row ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length,
      "repeated snapshots with the same kill-class error must trigger ONE heal, not N"
  end

  # F11: the dedup cache used to be permanent; a folder that got
  # re-killed later in the session would never re-heal. Bound the
  # window so re-heals after HEAL_REPEAT_INTERVAL_SECONDS go through.
  def test_heal_cache_re_permits_after_interval_elapses
    captured = stub_heal_capture(@model)
    folder = "/x/.hive-state/stages/4-execute/killed"
    row = make_error_row(slug: "killed", folder: folder, exit_code: 143)
    snap = snapshot_with([ row ])

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length, "first kill-class error fires one heal"

    # Re-permit by backdating the cache entry past the interval.
    interval = Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS
    cache = @model.instance_variable_get(:@healed_folders)
    cache[folder] = Time.now - (interval + 1)

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 2, captured.length,
      "after HEAL_REPEAT_INTERVAL_SECONDS the slot must re-permit so a fresh kill on " \
      "the same folder/slug pair gets re-healed instead of stranded"
  end

  def test_heal_cache_keeps_blocking_within_interval_window
    captured = stub_heal_capture(@model)
    folder = "/x/.hive-state/stages/4-execute/killed"
    row = make_error_row(slug: "killed", folder: folder, exit_code: 143)
    snap = snapshot_with([ row ])

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length

    # Backdate by half the interval — still within the dedup window.
    interval = Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS
    cache = @model.instance_variable_get(:@healed_folders)
    cache[folder] = Time.now - (interval / 2.0)

    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_equal 1, captured.length,
      "within the interval window a repeated snapshot must NOT re-heal — that's the dedup contract"
  end

  def test_snapshot_arrived_still_updates_the_model_after_auto_heal
    stub_heal_capture(@model)
    snap = snapshot_with([ make_error_row(slug: "k", folder: "/x/y", exit_code: 143) ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_same snap, @model.hive_model.snapshot,
      "auto-heal must not block the regular Update.apply path — the model still updates"
  end

  # F4: heal_marker passes --match-attr exit_code=<observed> so the
  # cross-process race window (auto-heal observes 143, concurrent
  # `hive run` writes 1, heal arrives) can't erase a real-failure
  # marker. Captures the actual argv handed to run_quiet!.
  def test_heal_marker_argv_includes_match_attr_for_observed_exit_code
    captured_argv = nil
    Hive::Tui::Subprocess.singleton_class.send(:alias_method, :__orig_run_quiet, :run_quiet!)
    Hive::Tui::Subprocess.define_singleton_method(:run_quiet!) do |argv|
      captured_argv = argv
      [ 0, "", "" ]
    end

    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/4-execute/killed", exit_code: 143)
    @model.send(:heal_marker, row)

    assert_equal [
      "hive", "markers", "clear",
      "/x/.hive-state/stages/4-execute/killed",
      "--name", "ERROR",
      "--match-attr", "exit_code=143"
    ], captured_argv,
      "heal_marker must scope the clear to the kill-class exit_code we observed"
  ensure
    Hive::Tui::Subprocess.singleton_class.send(:alias_method, :run_quiet!, :__orig_run_quiet)
    Hive::Tui::Subprocess.singleton_class.send(:remove_method, :__orig_run_quiet)
  end

  # ---- SubprocessExited diagnostic interception ----
  #
  # Pattern-matches the captured stderr in SUBPROCESS_LOG_PATH for
  # known setup-class errors and replaces the generic "exited N —
  # tail …" flash with an actionable message. Dogfood-driven:
  # `hive pr` exit 1 looped on a demo project that had no `origin`
  # remote — the user wanted "project is not set up" surfaced
  # directly so they could go fix the repo without `tail`-ing the log.

  def with_isolated_subprocess_log
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "hive-tui-subprocess.log")
      original = Hive::Tui::Subprocess::SUBPROCESS_LOG_PATH
      Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
      Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, log_path)
      begin
        yield log_path
      ensure
        Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
        Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, original)
      end
    end
  end

  def write_log_section(log_path, argv:, stderr:, exit_code:)
    File.open(log_path, "a") do |f|
      f.puts "----- 2026-04-28T11:05:47Z BEGIN: #{argv.join(' ')} -----"
      f.puts stderr
      f.puts "----- 2026-04-28T11:05:48Z END exit=#{exit_code}: #{argv.join(' ')} -----"
    end
  end

  def test_missing_origin_remote_shows_project_not_set_up
    with_isolated_subprocess_log do |log_path|
      write_log_section(
        log_path,
        argv: %w[hive pr hello-world-test-260425-431f --project demo --from 7-finalize],
        stderr: "hive: git push failed: fatal: 'origin' does not appear to be a git repository",
        exit_code: 1
      )

      @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 1))

      flash = @model.hive_model.flash
      refute_nil flash
      assert_match(/demo:/, flash, "diagnostic must name the project so the user knows which repo to fix")
      assert_match(/project not set up/i, flash,
        "user wanted 'project is not set up' surfaced directly so they can go create the repo manually")
      refute_match(/tail/, flash, "diagnostic supersedes the generic 'tail the log' hint")
    end
  end

  def test_unknown_failure_falls_back_to_default_flash
    with_isolated_subprocess_log do |log_path|
      write_log_section(
        log_path,
        argv: %w[hive develop slug --project p --from 3-plan],
        stderr: "some unknown error nobody patterns against",
        exit_code: 1
      )

      @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "develop", exit_code: 1))

      # No specific diagnostic → Update.apply's default "exited N — tail …" flash applies.
      flash = @model.hive_model.flash
      assert_match(/exited 1/, flash, "unrecognized failures fall back to the generic exit-code flash")
      assert_match(/tail/, flash, "fall-back flash includes the log-path hint")
    end
  end

  def test_zero_exit_does_not_flash_diagnostic
    @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "pr", exit_code: 0))
    assert_nil @model.hive_model.flash, "zero exit must not flash anything (success path is silent)"
  end

  # Last-resort safety net: an unhandled exception escaping
  # `BubbleModel#update` would unwind out of Bubbletea's runner and
  # tear down the alt-screen mid-frame. Pin that ANY StandardError
  # is converted into a flash + the TUI keeps running.
  def test_unhandled_exception_in_update_becomes_flash_not_crash
    # The safety net at `BubbleModel#update`'s rescue catches
    # exceptions NOT covered by per-handler rescues. Force a
    # genuinely unanticipated exception by overriding `translate`
    # on this BubbleModel INSTANCE — `translate` is the first thing
    # `update` calls before any per-handler rescue could catch, so
    # raising here exercises the top-level safety net. Per-instance
    # singleton method, no module-level mutation.
    @model.define_singleton_method(:translate) do |_msg|
      raise "synthetic unanticipated failure for the safety-net test"
    end
    _, cmd = @model.update(Hive::Tui::Messages::WindowSized.new(cols: 80, rows: 24))
    assert_nil cmd, "safety net returns nil cmd; never propagates exception"
    refute_nil @model.hive_model.flash, "exception must surface as a flash"
    assert_match(/internal error/i, @model.hive_model.flash,
      "flash must label this as the safety-net catchall, not a per-handler diagnostic")
  end

  def test_open_log_tail_flashes_when_no_log_files_exist
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "demo-260426-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      FileUtils.mkdir_p(File.join(project_root, ".hive-state", "logs", slug)) # logs dir but NO *.log files

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "6-review", slug: slug,
        folder: task_folder, state_file: nil, marker: nil, attrs: nil,
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "error", action_label: "Error", suggested_command: nil, next_action: nil,
        diagnostic: nil
      )

      # Must not raise — must convert NoLogFiles into a flashed model
      # change so the TUI keeps running.
      _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: row))
      assert_nil cmd, "no Cmd returned for the no-logs case"
      assert_match(/no logs yet for #{slug}/, @model.hive_model.flash)
      assert_equal :grid, @model.hive_model.mode,
        "must stay in grid mode, not flip to :log_tail with a missing log"
    end
  end

  # F3: Tail#poll! was never called — the view was frozen at the
  # bytes read by Tail#open!. open_log_tail now schedules a recurring
  # LOG_TAIL_POLL tick; the handler calls tail.poll! and reschedules
  # while mode is still :log_tail.
  def test_open_log_tail_returns_log_tail_poll_tick_cmd
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "tail-260428-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(project_root, ".hive-state", "logs", slug)
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "agent.log"), "first line\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "6-review", slug: slug,
        folder: task_folder, state_file: nil, marker: nil, attrs: nil,
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "agent_running", action_label: "Agent running", suggested_command: nil, next_action: nil,
        diagnostic: nil
      )

      _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: row))
      assert_kind_of Bubbletea::TickCommand, cmd,
        "successful open_log_tail must seed the LOG_TAIL_POLL tick so new bytes drain"
      assert_equal :log_tail, @model.hive_model.mode
    end
  end

  def test_open_log_tail_finds_review_logs_under_task_folder
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "review-tail-260508-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(task_folder, "logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "review-triage-pass04.log"), "review line\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "6-review", slug: slug,
        folder: task_folder, state_file: nil, marker: "review_stale", attrs: { "pass" => "4" },
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "recover_review", action_label: "Needs recovery", suggested_command: nil, next_action: nil,
        diagnostic: nil
      )

      _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: row))

      assert_kind_of Bubbletea::TickCommand, cmd
      assert_equal :log_tail, @model.hive_model.mode
      assert_equal File.join(logs, "review-triage-pass04.log"), @model.hive_model.tail_state.path
    end
  end

  def test_log_tail_poll_drains_new_bytes_and_reschedules
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.log")
      File.write(log_path, "first line\n")
      tail = Hive::Tui::LogTail::Tail.new(log_path)
      tail.open!
      wrapper = Hive::Tui::BubbleModel::LogTailContext.new(tail: tail, claude_pid_alive: true)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :log_tail, tail_state: wrapper),
        dispatch: @dispatch
      )

      # Append bytes after open!; tail's view is frozen until poll!
      File.write(log_path, "second line\n", mode: "a")
      assert_equal [ "first line" ], tail.lines(50),
        "without poll! the new bytes must not yet be visible — proves the regression existed"

      _, cmd = @model.update(Hive::Tui::Messages::LOG_TAIL_POLL)
      assert_includes tail.lines(50), "second line",
        "LOG_TAIL_POLL must drain new bytes via tail.poll!"
      assert_kind_of Bubbletea::TickCommand, cmd,
        "must reschedule a fresh tick while the user is still in :log_tail mode"
    end
  end

  def test_log_tail_poll_stops_rescheduling_after_mode_change_out
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, tail_state: nil),
      dispatch: @dispatch
    )
    _, cmd = @model.update(Hive::Tui::Messages::LOG_TAIL_POLL)
    assert_nil cmd,
      "LOG_TAIL_POLL must not reschedule after the user has left :log_tail mode"
  end

  # F6: every open_log_tail allocates a File handle inside Tail#open!.
  # apply_back was clearing tail_state but never calling tail.close!,
  # so each open/dismiss cycle leaked one FD until the process hit
  # ENFILE/EMFILE.
  def test_back_from_log_tail_closes_underlying_file_descriptor
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "agent.log")
      File.write(log_path, "first line\n")
      tail = Hive::Tui::LogTail::Tail.new(log_path)
      tail.open!
      file = tail.instance_variable_get(:@file)
      refute file.closed?, "fixture sanity: Tail#open! must leave the underlying File open"

      wrapper = Hive::Tui::BubbleModel::LogTailContext.new(tail: tail, claude_pid_alive: true)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :log_tail, tail_state: wrapper),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::BACK)
      assert file.closed?,
        "BACK in :log_tail mode must close the underlying File or every open/dismiss leaks one FD"
      assert_equal :grid, @model.hive_model.mode
      assert_nil @model.hive_model.tail_state,
        "Update.apply_back still owns clearing tail_state — F6 only adds the close! side effect"
    end
  end

  def test_back_from_other_modes_does_not_attempt_tail_close
    # Defensive: the close hook must not fire when mode != :log_tail
    # (no tail_state to close). Otherwise a stale wrapper from a
    # different code path could be touched on every grid-mode Esc.
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    # No exception means the guard works.
    @model.update(Hive::Tui::Messages::BACK)
    assert_equal :grid, @model.hive_model.mode
  end

  # F8: heal Threads must be tracked so App.run_charm's ensure block
  # can reap them at TUI exit. Pre-F8 the threads were unreferenced
  # after spawn — quitting mid-flight left zombies whose dispatch
  # eventually crashed against a dead runner.
  def test_kill_inflight_heals_joins_or_kills_in_flight_threads
    # Stub heal_marker with a slow stand-in so we can observe the
    # join-then-kill behavior under a deterministic deadline.
    @model.define_singleton_method(:heal_marker) do |_row|
      sleep 5 # well past JOIN_TIMEOUT_SECONDS
    end

    rows = 3.times.map { |i| make_error_row(slug: "k#{i}", folder: "/x/k#{i}", exit_code: 143) }
    threads = rows.map { |r| @model.send(:spawn_heal_thread, r) }
    assert_equal 3, threads.size
    threads.each { |t| assert t.alive?, "fixture sanity: stub thread should still be alive" }

    started = Time.now
    @model.kill_inflight_heals!
    elapsed = Time.now - started

    threads.each do |t|
      refute t.alive?, "kill_inflight_heals! must reap every tracked Thread"
    end
    assert elapsed < Hive::Tui::BubbleModel::JOIN_TIMEOUT_SECONDS + 1.0,
      "kill must respect the join timeout — got #{elapsed}s; deadline is " \
      "JOIN_TIMEOUT_SECONDS (#{Hive::Tui::BubbleModel::JOIN_TIMEOUT_SECONDS}s) plus a small buffer"
  end

  def test_spawn_heal_thread_self_prunes_when_heal_completes
    @model.define_singleton_method(:heal_marker) { |_row| nil }
    row = make_error_row(slug: "fast", folder: "/x/fast", exit_code: 143)
    t = @model.send(:spawn_heal_thread, row)
    t.join(2)

    tracked = @model.instance_variable_get(:@heal_threads)
    refute_includes tracked, t,
      "completed heal Thread must remove itself from @heal_threads to bound the list under long sessions"
  end

  def test_kill_inflight_heals_is_safe_when_no_threads_tracked
    # Common shape: TUI quits before any kill-class error arrived.
    @model.kill_inflight_heals!
    # Must not raise; nothing to assert beyond the absence of exception.
  end

  # ---- X-key drop on missing project ----
  # The drop handler is the gate: KeyMap always emits the singleton; the
  # gate ("only missing-path entries") is enforced here. Tests pin the
  # gate behavior because it's the safety net that prevents healthy
  # projects being silently deregistered by accident.

  def snapshot_with_projects(*specs)
    project_views = specs.each_with_index.map do |spec, _i|
      Hive::Tui::Snapshot::ProjectView.new(
        name: spec.fetch(:name),
        path: spec.fetch(:path),
        hive_state_path: File.join(spec[:path], ".hive-state"),
        error: spec[:error],
        rows: [].freeze
      ).freeze
    end
    Hive::Tui::Snapshot.new(generated_at: "2026-05-05T00:00:00Z", projects: project_views)
  end

  def test_x_key_drops_missing_project_and_resets_scope
    with_tmp_global_config do
      Hive::Config.register_project(name: "live", path: "/tmp/hive-live-#{rand(1_000_000)}")
      Hive::Config.register_project(name: "dead", path: "/tmp/hive-dead-#{rand(1_000_000)}")
      snap = snapshot_with_projects(
        { name: "live", path: "/tmp/live", error: nil },
        { name: "dead", path: "/tmp/dead", error: "missing_project_path" }
      )
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 2),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::DROP_SCOPED_PROJECT_IF_MISSING)

      remaining = Hive::Config.registered_projects.map { |p| p["name"] }
      assert_equal [ "live" ], remaining, "missing entry must be deregistered"
      assert_equal 0, @model.hive_model.scope,
                   "scope must reset to ★ All so the cursor doesn't hang on a vanished entry"
      assert_match(/dropped dead/, @model.hive_model.flash.to_s)
    end
  end

  def test_x_key_refuses_healthy_project_with_flash
    with_tmp_global_config do
      Hive::Config.register_project(name: "live", path: "/tmp/hive-live-#{rand(1_000_000)}")
      snap = snapshot_with_projects({ name: "live", path: "/tmp/live", error: nil })
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 1),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::DROP_SCOPED_PROJECT_IF_MISSING)

      assert_equal 1, Hive::Config.registered_projects.size,
                   "healthy project must NOT be deregistered by X"
      assert_match(/only missing projects/, @model.hive_model.flash.to_s)
    end
  end

  def test_x_key_at_all_scope_flashes_hint_without_modifying_registry
    with_tmp_global_config do
      Hive::Config.register_project(name: "live", path: "/tmp/hive-live-#{rand(1_000_000)}")
      snap = snapshot_with_projects({ name: "live", path: "/tmp/live", error: nil })
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 0),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::DROP_SCOPED_PROJECT_IF_MISSING)

      assert_equal 1, Hive::Config.registered_projects.size
      assert_match(/select a project/, @model.hive_model.flash.to_s)
    end
  end

  # P2 #18: ConfigError-rescue path on the X-key handler. A typoed
  # $HIVE_HOME (or any registry-config error) used to be dead code under
  # tests because the handler short-circuits on `snap.nil?` / scope=0
  # before reaching the rescue. Pin the rescue with a real ConfigError
  # raised from the registry mutation.
  def test_x_key_rescues_config_error_into_flash
    snap = snapshot_with_projects(
      { name: "dead", path: "/tmp/dead", error: "missing_project_path" }
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 1),
      dispatch: @dispatch
    )
    with_config_stub(:unregister_project, ->(*) { raise Hive::ConfigError, "bad config" }) do
      @model.update(Hive::Tui::Messages::DROP_SCOPED_PROJECT_IF_MISSING)
    end
    assert_match(/drop failed.*bad config/, @model.hive_model.flash.to_s,
                 "ConfigError on registry write must surface as a flash, not crash the runner")
  end

  # P2 #18: snapshot/registry race — the snapshot's project at the
  # cursor's scope index is `(missing)` but Config has already had the
  # entry forgotten by a concurrent shell between the keypress and the
  # handler. unregister_project returns nil; the handler must flash
  # rather than crash.
  def test_x_key_handles_concurrent_registry_mutation_via_nil_removed
    snap = snapshot_with_projects(
      { name: "vanished", path: "/tmp/vanished", error: "missing_project_path" }
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 1),
      dispatch: @dispatch
    )
    with_config_stub(:unregister_project, ->(*) { nil }) do
      @model.update(Hive::Tui::Messages::DROP_SCOPED_PROJECT_IF_MISSING)
    end
    assert_match(/no entry named/i, @model.hive_model.flash.to_s)
  end

  # Module-level stub helper (Hive::Config is a module, so MiniTest's
  # instance-method stub doesn't apply). Saves the original singleton
  # method and restores it in the ensure block — same shape as the
  # `with_editor_env` helper above, just for module methods.
  def with_config_stub(method, callable)
    original = Hive::Config.method(method)
    Hive::Config.singleton_class.send(:define_method, method, callable)
    yield
  ensure
    Hive::Config.singleton_class.send(:define_method, method, original) if original
  end

  def with_command_available_stub(callable)
    sentinel = Hive::Tui::Clipboard::DefaultShim.method(:command_available?)
    Hive::Tui::Clipboard::DefaultShim.define_singleton_method(:command_available?, &callable)
    yield
  ensure
    Hive::Tui::Clipboard::DefaultShim.define_singleton_method(:command_available?, sentinel) if sentinel
  end

  def with_env_overrides(overrides)
    originals = overrides.keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # ---- missing-clipboard-tool hint coverage ----
  def test_empty_paste_flashes_wayland_hint_when_wl_paste_absent
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    none = clipboard_none
    with_clipboard_probe_stub(->(**_kwargs) { none }) do
      with_command_available_stub(->(_name, **_kwargs) { false }) do
        with_env_overrides("XDG_SESSION_TYPE" => "wayland", "DISPLAY" => "") do
          @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
        end
      end
    end
    assert_match(/wl-clipboard/, @model.hive_model.flash.to_s,
      "Wayland session without wl-paste should hint about wl-clipboard")
  end

  def test_empty_paste_flashes_x11_hint_when_xclip_absent
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    none = clipboard_none
    with_clipboard_probe_stub(->(**_kwargs) { none }) do
      with_command_available_stub(->(_name, **_kwargs) { false }) do
        with_env_overrides("XDG_SESSION_TYPE" => "x11", "DISPLAY" => ":0") do
          @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
        end
      end
    end
    assert_match(/xclip/, @model.hive_model.flash.to_s,
      "X11 session without xclip should hint about xclip")
  end

  def test_empty_paste_silent_when_no_session_env_vars
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    none = clipboard_none
    with_clipboard_probe_stub(->(**_kwargs) { none }) do
      with_command_available_stub(->(_name, **_kwargs) { false }) do
        with_env_overrides("XDG_SESSION_TYPE" => "", "DISPLAY" => "") do
          @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
        end
      end
    end
    refute_match(/wl-clipboard|xclip/, @model.hive_model.flash.to_s,
      "no Wayland AND no X11 env => no missing-tool hint")
  end

  def test_clipboard_tool_hint_latch_resets_after_successful_image_paste
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    none = clipboard_none
    # First paste fires the wayland hint and latches the flag.
    with_clipboard_probe_stub(->(**_kwargs) { none }) do
      with_command_available_stub(->(_name, **_kwargs) { false }) do
        with_env_overrides("XDG_SESSION_TYPE" => "wayland", "DISPLAY" => "") do
          @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
        end
      end
    end
    assert @model.instance_variable_get(:@clipboard_tool_hint_shown),
      "first hint must set the latch"
    # Successful image paste should reset the latch.
    probe_result = clipboard_image_bytes
    with_clipboard_probe_stub(->(**_kwargs) { probe_result }) do
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
    end
    refute @model.instance_variable_get(:@clipboard_tool_hint_shown),
      "after a successful image paste the latch should release so a future install/uninstall is reflected"
  ensure
    Hive::Tui::ComposerStaging.cleanup!(@model&.hive_model&.new_idea_staging_dir)
  end

  def test_oversize_image_clipboard_surfaces_flash_without_corrupting_buffer
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea, new_idea_buffer: "title"),
      dispatch: @dispatch
    )
    oversize = Hive::Tui::Clipboard::OVERSIZE_IMAGE
    with_clipboard_probe_stub(->(**_kwargs) { oversize }) do
      @model.update(Hive::Tui::Messages::RawTextInput.new(text: "", paste: true))
    end
    assert_equal "title", @model.hive_model.new_idea_buffer,
      "buffer must NOT receive the oversize-image text"
    assert_match(/too large/i, @model.hive_model.flash.to_s)
  end
end
