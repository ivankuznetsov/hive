require "test_helper"
require "hive/tui/bubble_model"

# Pin the BubbleModel adapter's translation/dispatch contract:
# framework messages → Hive Messages, KeyMessage → KeyMap.message_for,
# DispatchCommand → takeover_command, sub-mode entries set state.
class HiveTuiBubbleModelTest < Minitest::Test
  include HiveTestHelper

  EmptyUpdateState = Data.define(:nudge)
  RecoveryReceipt = Data.define(:status, :summary) do
    def human_summary = summary
  end
  FakeRecoveryWriter = Struct.new(:calls, :handler, keyword_init: true) do
    def recover!(**kwargs)
      calls << kwargs
      return handler.call(**kwargs) if handler

      RecoveryReceipt.new(status: "queued", summary: "Recovery queued — request tui-test")
    end
  end

  def setup
    @messages = []
    @dispatch = ->(m) { @messages << m }
    @recovery_writer = FakeRecoveryWriter.new(calls: [])
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch,
      recovery_writer: @recovery_writer,
      update_state: EmptyUpdateState.new(nudge: nil)
    )
  end

  def key_message(key_type, runes: [])
    Bubbletea::KeyMessage.new(key_type: key_type, runes: runes)
  end

  def mouse_message(button:, action: Bubbletea::MouseMessage::ACTION_PRESS)
    Bubbletea::MouseMessage.new(x: 1, y: 1, button: button, action: action)
  end

  def make_task_row(action_key: "needs_input", slug: "some-slug", stage: "2-brainstorm",
                    state_file: "/tmp/hive/some-slug/brainstorm.md",
                    suggested_command: "hive brainstorm some-slug --from 2-brainstorm",
                    marker: "waiting", attrs: {}, folder: nil,
                    folder_mtime: nil,
                    action_label: "Needs your input", next_action: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo", stage: stage, slug: slug, folder: folder || "/tmp/hive/#{slug}",
      state_file: state_file, marker: marker, attrs: attrs, mtime: nil,
      folder_mtime: folder_mtime, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
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

  def with_zero_usage
    with_replaced_singleton_method(Hive::UsageDb, :aggregate, ->(scope:, **_kwargs) {
      Hive::UsageDb.zero_aggregate
    }) { yield }
  end

  def test_view_renders_implementation_identity_detail_mode
    identity = { "generation" => 1, "pending" => false, "stages" => {} }
    row = make_task_row.with(implementation_identity: identity)
    state = Hive::Tui::Model::ImplementationIdentityDetailState.new(row: row)
    bubble = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :implementation_identity_detail,
        implementation_identity_detail_state: state
      ),
      dispatch: @dispatch,
      update_state: EmptyUpdateState.new(nudge: nil)
    )

    assert_includes bubble.view, "Implementation ownership"
  end

  def write_idea_md(dir, original_text:, slug: "some-slug", created_at: "2026-05-20T00:00:00Z")
    indented_original = original_text.lines.map { |line| "  #{line.chomp}" }
    body = [
      "---",
      "slug: #{slug}",
      "created_at: #{created_at}",
      "original_text: |",
      *indented_original,
      "---",
      "",
      "# #{slug}",
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

  def write_review_doc(path, accepted: false)
    mark = accepted ? "x" : " "
    File.write(path, "## High\n- [#{mark}] First finding: useful rationale\n")
    Hive::Findings::Document.new(path)
  end

  def with_staged_image_attachment
    staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
    staging_path = File.join(staging_dir, "image-1.png")
    File.binwrite(staging_path, "image".b)
    attachment = Hive::Tui::Model::Attachment.new(
      label: "image1",
      staging_path: staging_path,
      ext: "png"
    )
    yield(staging_dir, staging_path, attachment)
  ensure
    Hive::Tui::ComposerStaging.cleanup!(staging_dir) if staging_dir && File.exist?(staging_dir)
  end

  def make_task_folder(root, stage: "2-brainstorm", slug: "some-slug")
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    folder
  end

  def make_log(root, slug: "some-slug", name: "run.log", text: "log\n", mtime: Time.now)
    dir = File.join(root, ".hive-state", "logs", slug)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, text)
    File.utime(mtime, mtime, path)
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

  def test_z_opens_archive_pane
    km = Bubbletea::KeyMessage.new(key_type: 0, runes: [ "z".ord ])
    @model.update(km)
    assert_equal :archive, @model.hive_model.mode
  end

  def test_open_archive_pane_requests_archive_refresh
    calls = 0
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch,
      archive_refresh: -> { calls += 1 }
    )

    @model.update(Hive::Tui::Messages::OPEN_ARCHIVE_PANE)

    assert_equal 1, calls
    assert_equal :archive, @model.hive_model.mode
  end

  # U4 end-to-end wiring (App#run_charm injects
  # state_source.method(:request_archive_refresh) as the archive_refresh
  # hook). BubbleModel calling its hook and StateSource#request_archive_refresh
  # are each unit-tested in isolation; this pins the actual bound-method
  # handoff so the binding can't be dropped/mis-wired with both halves green.
  def test_open_archive_pane_marks_state_source_cache_dirty_through_bound_method
    require "hive/tui/state_source"
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)
    model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial,
      dispatch: @dispatch,
      archive_refresh: source.method(:request_archive_refresh)
    )
    refute source.instance_variable_get(:@archive_refresh_dirty),
           "a fresh StateSource starts with a clean archive cache"

    model.update(Hive::Tui::Messages::OPEN_ARCHIVE_PANE)

    assert source.instance_variable_get(:@archive_refresh_dirty),
           "opening the archive pane must flip StateSource's dirty flag via the bound hook"
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

  def test_usage_footer_uses_task_scope_when_tasks_pane_focused
    row = make_task_row(slug: "task-one", action_key: "ready_to_plan")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        snapshot: snapshot_with([ row ]),
        cursor: [ 0, 0 ],
        pane_focus: :right
      ),
      dispatch: @dispatch
    )
    scopes = []

    with_replaced_singleton_method(Hive::UsageDb, :aggregate, ->(scope:, **_kwargs) {
      scopes << scope
      Hive::UsageDb.zero_aggregate
    }) do
      @model.send(:usage_footer_line, 120)
    end

    assert_equal [ { project_slug: "demo", task_slug: "task-one" } ], scopes
  end

  def test_usage_footer_uses_project_scope_when_project_pane_focused
    row = make_task_row(slug: "task-one", action_key: "ready_to_plan")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        snapshot: snapshot_with([ row ]),
        cursor: [ 0, 0 ],
        scope: 1,
        pane_focus: :left
      ),
      dispatch: @dispatch
    )
    scopes = []

    with_replaced_singleton_method(Hive::UsageDb, :aggregate, ->(scope:, **_kwargs) {
      scopes << scope
      Hive::UsageDb.zero_aggregate
    }) do
      @model.send(:usage_footer_line, 120)
    end

    assert_equal [ { project_slug: "demo" } ], scopes
  end

  def test_current_row_uses_archive_filtered_grid_projection
    hidden = make_task_row(
      action_key: "archived",
      action_label: "Archived",
      slug: "old-archived",
      stage: "9-done",
      marker: "complete",
      folder_mtime: (Time.now - (5 * 86_400)).utc.iso8601
    )
    visible = make_task_row(action_key: "ready_to_plan", action_label: "Ready to plan", slug: "visible-row")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        snapshot: snapshot_with([ hidden, visible ]),
        cursor: [ 0, 0 ]
      ),
      dispatch: @dispatch
    )

    row = @model.send(:current_row)

    assert_equal "visible-row", row.slug
  end

  def test_usage_footer_defaults_to_all_scope_without_selection
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(cursor: nil, pane_focus: :right),
      dispatch: @dispatch
    )
    scopes = []

    with_replaced_singleton_method(Hive::UsageDb, :aggregate, ->(scope:, **_kwargs) {
      scopes << scope
      Hive::UsageDb.zero_aggregate
    }) do
      @model.send(:usage_footer_line, 120)
    end

    assert_equal [ {} ], scopes
  end

  def test_narrow_default_footer_drops_hint_but_keeps_usage
    with_replaced_singleton_method(Hive::UsageDb, :aggregate, ->(scope:, **_kwargs) {
      Hive::UsageDb.zero_aggregate
    }) do
      out = @model.send(:default_footer, 70)
      assert_includes out, "tokens"
      refute_includes out, "[Tab]"
    end
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
      Bubbletea::KeyMessage::KEY_PGUP => :key_pgup,
      Bubbletea::KeyMessage::KEY_PGDOWN => :key_pgdn,
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

  def test_translate_key_with_unknown_mode_returns_noop
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :unknown_mode),
      dispatch: @dispatch
    )

    msg = @model.send(:translate_key, key_message(Bubbletea::KeyMessage::KEY_ENTER))

    assert_same Hive::Tui::Messages::NOOP, msg
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

  def test_translate_mouse_wheel_down_in_help_returns_help_scroll
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )

    msg = @model.send(
      :translate,
      mouse_message(button: Bubbletea::MouseMessage::BUTTON_WHEEL_DOWN)
    )

    assert_kind_of Hive::Tui::Messages::HelpScroll, msg
    assert_equal :down, msg.direction
    assert_equal Hive::Tui::BubbleModel::HELP_WHEEL_SCROLL_LINES, msg.amount
  end

  def test_translate_mouse_wheel_up_in_help_returns_help_scroll
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )

    msg = @model.send(
      :translate,
      mouse_message(button: Bubbletea::MouseMessage::BUTTON_WHEEL_UP)
    )

    assert_kind_of Hive::Tui::Messages::HelpScroll, msg
    assert_equal :up, msg.direction
    assert_equal Hive::Tui::BubbleModel::HELP_WHEEL_SCROLL_LINES, msg.amount
  end

  def test_translate_mouse_wheel_in_grid_mode_is_noop
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )

    msg = @model.send(
      :translate,
      mouse_message(button: Bubbletea::MouseMessage::BUTTON_WHEEL_DOWN)
    )

    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_translate_non_wheel_mouse_press_is_noop
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )

    msg = @model.send(
      :translate,
      mouse_message(button: Bubbletea::MouseMessage::BUTTON_LEFT)
    )

    assert_same Hive::Tui::Messages::NOOP, msg
  end

  def test_translate_horizontal_wheel_in_help_is_noop
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :help),
      dispatch: @dispatch
    )

    # Button 6 is a horizontal-wheel event (wheel? is true) but is neither
    # WHEEL_UP nor WHEEL_DOWN, so the help overlay must ignore it.
    horizontal_wheel = mouse_message(button: 6)
    assert horizontal_wheel.wheel?, "button 6 must register as a wheel event"

    msg = @model.send(:translate, horizontal_wheel)

    assert_same Hive::Tui::Messages::NOOP, msg
  end

  # ---- View dispatch by mode ----

  def test_view_renders_grid_in_grid_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    out = with_zero_usage { @model.view }
    assert_includes out, "Tasks ·"
    assert_includes out, "tokens"
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

  def test_view_composes_idea_preview_as_full_frame_with_default_footer
    state = Hive::Tui::Model::InfoPanelState.new(
      slug: "some-slug",
      stage: "2-brainstorm",
      created_at: "2026-05-22T22:40:00Z",
      original_text: "original idea",
      folder_path: "/tmp/.hive-state/stages/2-brainstorm/some-slug",
      latest_log_path: "/tmp/.hive-state/logs/some-slug/run.log",
      stage_extra: "brainstorm notes"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :idea_preview,
        info_panel_state: state,
        rows: 20,
        cols: 180
      ),
      dispatch: @dispatch
    )
    out = with_zero_usage { @model.view }

    assert_includes out, "Info: some-slug"
    assert_includes out, "original idea"
    assert_includes out, "brainstorm notes"
    assert_includes out, "tokens"
    assert_includes out, "[i] info"
    refute_includes out, "Projects"
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

  def test_red_status_detail_view_renders_header_panels_log_artifacts_and_action_bar
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "detail-view-260523-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(task_folder, "logs")
      artifact = "/tmp/errors-02.md"
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "review-fix-pass02.log"), (1..8).map { |i| "line-#{i}" }.join("\n") + "\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: "alpha", stage: "6-review", slug: slug,
        folder: task_folder, state_file: File.join(task_folder, "task.md"),
        worktree_path: File.join(project_root, "worktrees", slug),
        marker: "review_error", attrs: { "phase" => "fix", "pass" => "2" },
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "recover_review", action_label: "Needs recovery",
        suggested_command: nil, next_action: nil,
        diagnostic: {
          "summary" => "REVIEW_ERROR phase=fix pass=2",
          "detail" => "Fix agent failed before tests completed.",
          "artifact_paths" => [ artifact ],
          "marker_signature" => "sig"
        }
      )
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(cols: 100, rows: 30),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
      output = @model.view

      assert_includes output, "RED · alpha/6-review · #{slug}"
      assert output.lines.any? { |line| line.start_with?("╭") || line.start_with?("+") },
             "rendered detail should include a bordered panel"
      assert_includes output, "Why:"
      assert_includes output, "Log · last 7 of 8 lines"
      assert_includes output, "line-2"
      assert_includes output, "line-8"
      assert_includes output, artifact
      assert_includes output, "[Enter] Recover"
      assert_includes output, "Open in agent"
      assert_includes output.lines[-2], "[Esc] back"

      # Pin section ordering: header, reason summary, action chips,
      # artifacts, then the log snapshot. Use line-index lookups rather
      # than byte offsets so two sections collapsing onto the same row
      # cannot pass the ordering chain.
      lines = output.lines
      header_idx = lines.find_index { |line| line.include?("RED · alpha/6-review") }
      reason_idx = lines.find_index { |line| line.include?("Why:") }
      action_idx = lines.find_index { |line| line.include?("[Enter] Recover") }
      artifact_idx = lines.find_index { |line| line.include?(artifact) }
      log_idx = lines.find_index { |line| line.include?("Log · last 7 of 8 lines") }

      assert_operator header_idx, :<, reason_idx, "header must come before the reason summary"
      assert_operator reason_idx, :<, action_idx, "reason summary must come before actions"
      assert_operator action_idx, :<, artifact_idx, "actions must come before artifacts"
      assert_operator artifact_idx, :<, log_idx, "artifacts must come before the log snapshot"
    end
  end

  # U10 at 80×24: mirror of the 100×30 composition pin so a regression
  # at the narrower-but-still-tall layout boundary can't slip past.
  def test_red_status_detail_view_composes_sections_at_80x24
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "detail-view-80x24-260523-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(task_folder, "logs")
      artifact = "/tmp/errors-02.md"
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "review-fix-pass02.log"), (1..8).map { |i| "line-#{i}" }.join("\n") + "\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: "alpha", stage: "6-review", slug: slug,
        folder: task_folder, state_file: File.join(task_folder, "task.md"),
        worktree_path: File.join(project_root, "worktrees", slug),
        marker: "review_error", attrs: { "phase" => "fix", "pass" => "2" },
        mtime: nil, age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
        action_key: "recover_review", action_label: "Needs recovery",
        suggested_command: nil, next_action: nil,
        diagnostic: {
          "summary" => "REVIEW_ERROR phase=fix pass=2",
          "detail" => "Fix agent failed before tests completed.",
          "artifact_paths" => [ artifact ],
          "marker_signature" => "sig"
        }
      )
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(cols: 80, rows: 24),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
      output = @model.view

      header_idx = output.index("RED · alpha/6-review")
      reason_idx = output.index("Why:")
      action_idx = output.index("[Enter] Recover")

      refute_nil header_idx, "header must render"
      refute_nil reason_idx, "reason summary must render"
      refute_nil action_idx, "action bar must render"
      assert_operator header_idx, :<, reason_idx
      assert_operator reason_idx, :<, action_idx
      assert_includes output.lines[-2], "[Esc] back"
    end
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

  def test_view_renders_log_tail_mode
    tail_state = Struct.new(:path, :claude_pid_alive) do
      def lines(count)
        [ "first log line", "second log line" ].first(count)
      end
    end.new("/tmp/hive/agent.log", false)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :log_tail, tail_state: tail_state, cols: 80, rows: 5
      ),
      dispatch: @dispatch
    )

    out = @model.view

    assert_includes out, "/tmp/hive/agent.log"
    assert_includes out, "first log line"
    assert_includes out, "stale"
  end

  def test_view_renders_archive_mode
    row = make_task_row(
      action_key: "archived",
      action_label: "Archived",
      slug: "archived-row",
      stage: "9-done",
      marker: "complete"
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :archive,
        snapshot: snapshot_with([ row ]),
        cols: 100,
        rows: 20
      ),
      dispatch: @dispatch
    )

    out = @model.view

    assert_includes out, "Archive · all done tasks"
    assert_includes out, "archived-row"
  end

  def test_view_renders_red_status_detail_mode
    row = make_task_row(
      action_key: "error", action_label: "Error", marker: "error",
      attrs: { "exit_code" => "1" }
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :red_status_detail,
        red_status_detail_state: state,
        cols: 100,
        rows: 12
      ),
      dispatch: @dispatch
    )

    out = @model.view

    assert_includes out, "Task needs attention"
    assert_includes out, "some-slug"
    assert_includes out, "Project: demo"
  end

  def test_view_falls_back_to_grid_for_unknown_mode
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :unknown_mode, cols: 100),
      dispatch: @dispatch
    )

    out = @model.view

    assert_includes out, "Tasks ·"
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
    assert_includes out, "Ready to plan", "right pane task row must render"
    assert_includes out, "Tasks ·",       "tasks pane title must render"
    assert_includes out, "[Tab] switch",  "default footer hints must appear"
    assert_includes out, "[Enter] action", "Enter footer hint must describe contextual behavior"
    refute_includes out, "[Enter] open",   "Enter is not only an open action"
  end

  def test_default_footer_hint_advertises_info_between_help_and_quit
    hint = @model.send(:footer_hint)
    assert_equal "[Tab] switch  [Enter] action  [n] new  [/] filter  [?] help  [i] info  [q] quit",
                 hint
    assert_match(/\[\?\] help  \[i\] info  \[q\] quit/, hint)
    refute_includes hint, "[o] open",
                    "`o` remains discoverable through the help overlay, not the fixed footer"
  end

  def test_default_footer_renders_full_hint_at_wide_width
    out = with_zero_usage { @model.send(:default_footer, 180) }

    assert_includes out, "tokens"
    assert_includes out, "[i] info"
    assert_includes out, "[q] quit"
    assert_operator out.index("[Tab] switch"), :<, out.index("tokens"),
                    "hint block must precede token block at wide width"
  end

  def test_default_footer_omits_hidden_archived_notice
    rows = 12.times.map do |idx|
      make_task_row(
        action_key: "archived",
        action_label: "Archived",
        slug: "old-archived-#{idx}",
        stage: "9-done",
        marker: "complete",
        folder_mtime: (Time.now - (5 * 86_400)).utc.iso8601
      )
    end
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snapshot_with(rows), mode: :grid),
      dispatch: @dispatch
    )

    out = with_zero_usage { @model.send(:default_footer, 180) }

    refute_includes out, "hidden — open Archive pane"
  end

  def test_default_footer_flash_takes_precedence_over_usage_hint
    row = make_task_row(
      action_key: "archived",
      action_label: "Archived",
      stage: "9-done",
      marker: "complete",
      folder_mtime: (Time.now - (5 * 86_400)).utc.iso8601
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        snapshot: snapshot_with([ row ]),
        mode: :grid,
        flash: "working",
        flash_set_at: Time.now
      ),
      dispatch: @dispatch
    )

    out = with_zero_usage { @model.send(:default_footer, 180) }

    assert_includes out, "working"
    refute_includes out, "hidden — open Archive pane"
    refute_includes out, "[Tab] switch"
  end

  def test_default_footer_fits_full_hint_at_exact_boundary_width
    hint = @model.send(:footer_hint)
    usage = Hive::Tui::Views::UsageFooter.text(Hive::UsageDb.zero_aggregate)
    out = with_zero_usage { @model.send(:default_footer, "#{hint} · #{usage}".length) }

    assert_includes out, "tokens"
    assert_includes out, "[i] info"
    assert_includes out, "[q] quit"
    assert_includes out, " · ",
                    "hint and usage blocks must remain joined by the ` · ` separator"
    refute out.end_with?("…"),
           "footer at exact hint width should not truncate, got #{out.inspect}"
  end

  def test_default_footer_truncates_tokens_first_on_overflow_above_threshold
    hint = @model.send(:footer_hint)
    usage = Hive::Tui::Views::UsageFooter.text(Hive::UsageDb.zero_aggregate)
    tail_label = "tokens"
    assert usage.end_with?(tail_label),
           "test premise: usage text must end with `tokens` label, got #{usage.inspect}"
    full_width = "#{hint} · #{usage}".length
    out = with_zero_usage { @model.send(:default_footer, full_width - 5) }

    assert_includes out, "[Tab] switch",
                    "hint block must survive when overflow clips from the right"
    refute out.end_with?(tail_label),
           "trailing token label must be the first content clipped on overflow"
  end

  def test_default_footer_narrow_branch_drops_hints_and_keeps_usage
    out = with_zero_usage { @model.send(:default_footer, 76) }

    assert_includes out, "tokens"
    refute_includes out, "[Tab]"
    refute_includes out, "[?] help"
  end

  def test_default_footer_narrow_branch_omits_hidden_notice
    rows = 12.times.map do |idx|
      make_task_row(
        action_key: "archived",
        action_label: "Archived",
        slug: "old-archived-#{idx}",
        stage: "9-done",
        marker: "complete",
        folder_mtime: (Time.now - (5 * 86_400)).utc.iso8601
      )
    end
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snapshot_with(rows), mode: :grid),
      dispatch: @dispatch
    )

    out = with_zero_usage { @model.send(:default_footer, 76) }

    assert_includes out, "tokens", "narrow footer must keep the usage block alongside the hidden notice"
    refute_includes out, "hidden", "narrow footer must not burn space on archived-hidden status"
    refute_includes out, "[Tab]", "narrow footer must drop key hints even when a hidden notice is present"
  end

  def test_grid_mode_omits_persistent_metadata_strip
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 100, scope: 1, filter: "abc"),
      dispatch: @dispatch
    )

    out = with_zero_usage { @model.view }

    refute_includes out, "hive tui  scope="
    refute_includes out, "generated_at=2026-05-01"
  end

  def test_header_strip_formats_snapshot_metadata_when_called_directly
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 1, filter: "abc"),
      dispatch: @dispatch
    )

    out = @model.send(:header_strip, 200)

    assert_includes out, "hive tui"
    assert_includes out, "scope=hive"
    assert_includes out, "filter=abc"
    assert_includes out, "generated_at=2026-05-01"
  end

  def test_header_strip_truncates_to_width
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => [] } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snap, scope: 1, filter: "abc"),
      dispatch: @dispatch
    )

    out = @model.send(:header_strip, 20)

    assert_operator Hive::Tui::Text.sanitize(out).length, :<=, 20
  end

  def test_grid_mode_clamps_rendered_height_to_terminal_rows
    tasks = 20.times.map do |idx|
      { "slug" => "task-#{idx}", "stage" => "2-brainstorm", "action" => "ready_to_plan",
        "action_label" => "Ready to plan", "age_seconds" => 60, "marker" => "complete" }
    end
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01",
      "projects" => [ { "name" => "hive", "tasks" => tasks } ]
    )
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid, snapshot: snap, cols: 100, rows: 8, cursor: [ 0, 19 ]),
      dispatch: @dispatch
    )

    out = with_zero_usage { @model.view }

    assert_operator out.lines.count, :<=, 8
    assert_includes out, "task-19", "viewport must follow the selected task after vertical resize"
    refute_includes out, "task-0", "offscreen rows must be clipped instead of pushing the footer away"
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

  def with_singleton_method_stub(receiver, name, stub_proc)
    sentinel = receiver.method(name)
    receiver.define_singleton_method(name, &stub_proc)
    yield
  ensure
    receiver.define_singleton_method(name, sentinel) if sentinel
  end

  def test_red_status_autofix_force_delegates_to_task_action_predicate
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      marker: "review_stale",
      attrs: { "pass" => "4" },
      suggested_command: nil
    )
    captured = nil

    with_singleton_method_stub(Hive::TaskAction, :max_passes_review_stale_with_escalations?, lambda { |**kwargs|
      captured = kwargs
      true
    }) do
      assert_equal true, @model.send(:red_status_autofix_force?, row)
    end

    assert_equal({ folder: row.folder, marker_name: "review_stale", attrs: { "pass" => "4" } }, captured)
  end

  def with_run_takeover_stub(stub_proc)
    sentinel = Hive::Tui::Subprocess.method(:run_takeover_child_sync)
    Hive::Tui::Subprocess.define_singleton_method(:run_takeover_child_sync, &stub_proc)
    yield
  ensure
    Hive::Tui::Subprocess.define_singleton_method(:run_takeover_child_sync, sentinel) if sentinel
  end

  def with_agent_profile_lookup_stub(stub_proc)
    sentinel = Hive::AgentProfiles.method(:lookup)
    Hive::AgentProfiles.define_singleton_method(:lookup, &stub_proc)
    yield
  ensure
    Hive::AgentProfiles.define_singleton_method(:lookup, sentinel) if sentinel
  end

  ManualProfileStub = Struct.new(:bin, :add_dir_flag, :version_checked, :preflight_checked, keyword_init: true) do
    def check_version!
      self.version_checked = true
    end

    def preflight!
      self.preflight_checked = true
    end
  end

  def with_manual_task_context(stage: "4-execute", slug: "manual-task",
                               worktree: true, context_stages: %w[1-inbox 3-plan 4-execute],
                               config: nil)
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      stages_root = File.join(hive_state, "stages")
      FileUtils.mkdir_p(stages_root)
      File.write(File.join(hive_state, "config.yml"), config.to_yaml) if config

      (context_stages | [ stage ]).each do |stage_dir|
        stage_name = stage_dir.split("-", 2).last
        folder = File.join(stages_root, stage_dir, slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, Hive::Task::STATE_FILES.fetch(stage_name))
        File.write(state_file, "# #{stage_name}\n") unless File.exist?(state_file)
      end

      folder = File.join(stages_root, stage, slug)
      stage_name = stage.split("-", 2).last
      state_file = File.join(folder, Hive::Task::STATE_FILES.fetch(stage_name))
      worktree_path = File.join(project_root, "worktrees", slug)
      if worktree
        FileUtils.mkdir_p(worktree_path)
        File.write(File.join(folder, "worktree.yml"), { "path" => worktree_path }.to_yaml)
      end

      row = make_task_row(
        action_key: "needs_input",
        action_label: "Needs your input",
        slug: slug,
        stage: stage,
        folder: folder,
        state_file: state_file,
        marker: "none",
        attrs: {}
      )
      yield(project_root, hive_state, folder, state_file, worktree_path, row)
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

  def test_empty_paste_outside_new_idea_short_circuits_without_clipboard_probe
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :grid),
      dispatch: @dispatch
    )
    before = @model.hive_model

    with_clipboard_probe_stub(->(**_kwargs) { flunk "clipboard probe should not run" }) do
      _, cmd = @model.update(Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: ""))
      assert_nil cmd
    end

    assert_equal before, @model.hive_model
  end

  def test_empty_image_clipboard_probe_flashes_without_placeholder
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )

    with_clipboard_probe_stub(->(**_kwargs) { Hive::Tui::Clipboard::ProbeResult.empty_image }) do
      @model.update(Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: ""))
    end

    assert_equal "", @model.hive_model.new_idea_buffer
    assert_equal [], @model.hive_model.new_idea_attachments
    assert_match(/image file is empty/, @model.hive_model.flash.to_s)
  end

  def test_clipboard_timeout_flashes_on_second_consecutive_timeout
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :new_idea),
      dispatch: @dispatch
    )
    timeout = Hive::Tui::Clipboard::ProbeResult.clipboard_timeout

    with_clipboard_probe_stub(->(**_kwargs) { timeout }) do
      @model.update(Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: ""))
      refute_match(/clipboard probe timed out/, @model.hive_model.flash.to_s)
      assert_equal 1, @model.instance_variable_get(:@clipboard_consecutive_timeouts)

      @model.update(Hive::Tui::Messages::NewIdeaPasteRequested.new(raw_text: ""))
    end

    assert_match(/clipboard probe timed out/, @model.hive_model.flash.to_s)
    assert_equal 0, @model.instance_variable_get(:@clipboard_consecutive_timeouts)
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


  def test_cleanup_new_idea_staging_warns_when_guard_refuses_path
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        new_idea_staging_dir: "/outside/tmp",
        new_idea_staging_tmp_root: Dir.tmpdir
      ),
      dispatch: @dispatch
    )
    logs = []

    with_singleton_method_stub(Hive::Tui::ComposerStaging, :cleanup!, lambda { |_dir, **_kwargs|
      raise ArgumentError, "refusing outside tmpdir"
    }) do
      with_singleton_method_stub(Hive::Tui::Debug, :log, lambda { |tag, message = nil|
        logs << [ tag, message ]
      }) do
        _out, err = capture_io { @model.send(:cleanup_new_idea_staging) }
        assert_match(/staging cleanup refused/, err)
      end
    end

    assert_nil @model.hive_model.new_idea_staging_dir
    assert_nil @model.hive_model.new_idea_staging_tmp_root
    assert_equal "new_idea_staging", logs.dig(0, 0)
    assert_match(/cleanup refused/, logs.dig(0, 1))
  end

  def test_cleanup_new_idea_staging_warns_when_filesystem_cleanup_fails
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        new_idea_staging_dir: File.join(Dir.tmpdir, "hive-staging-fail"),
        new_idea_staging_tmp_root: Dir.tmpdir
      ),
      dispatch: @dispatch
    )
    logs = []

    with_singleton_method_stub(Hive::Tui::ComposerStaging, :cleanup!, lambda { |_dir, **_kwargs|
      raise Errno::EACCES, "permission denied"
    }) do
      with_singleton_method_stub(Hive::Tui::Debug, :log, lambda { |tag, message = nil|
        logs << [ tag, message ]
      }) do
        _out, err = capture_io { @model.send(:cleanup_new_idea_staging) }
        assert_match(/staging cleanup failed/, err)
      end
    end

    assert_equal "new_idea_staging", logs.dig(0, 0)
    assert_match(/cleanup failed/, logs.dig(0, 1))
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

  # NEW-2: all-unhealthy flash used to unconditionally suggest registry
  # cleanup, but `hive prune` only drops `missing_project_path` rows. With
  # every project at `not_initialised`, the suggestion would land the
  # operator on refusal output. The fix branches on the error mix.
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
    assert_match(/hive prune/i, @model.hive_model.flash.to_s,
                 "missing-only set must steer the operator at the hive prune surface")
    refute_match(/press X/i, @model.hive_model.flash.to_s,
                 "X now drops the focused task, not missing registry entries")
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

  def test_rich_new_idea_submission_with_chosen_project_missing_bounces_to_picker
    with_staged_image_attachment do |staging_dir, staging_path, attachment|
      snap = Hive::Tui::Snapshot.from_payload(
        "generated_at" => "2026-05-06",
        "projects" => [ { "name" => "alpha", "tasks" => [] } ]
      )
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(
          mode: :new_idea,
          snapshot: snap,
          scope: 0,
          new_idea_project_name: "ghost",
          new_idea_buffer: "see [image1]",
          new_idea_cursor: 12,
          new_idea_attachments: [ attachment ],
          new_idea_staging_dir: staging_dir
        ),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)

      assert_equal :new_idea_project, @model.hive_model.mode
      assert_nil @model.hive_model.new_idea_project_name
      assert_equal "see [image1]", @model.hive_model.new_idea_buffer
      assert_equal [ attachment ], @model.hive_model.new_idea_attachments
      assert File.exist?(staging_path), "staged image must survive the project re-pick bounce"
      assert_match(/"ghost".*not available.*choose another project/i, @model.hive_model.flash.to_s)
    end
  end

  def test_rich_new_idea_submission_with_unhealthy_explicit_scope_preserves_compose_state
    with_staged_image_attachment do |staging_dir, staging_path, attachment|
      snap = Hive::Tui::Snapshot.from_payload(
        "generated_at" => "2026-05-06",
        "projects" => [ { "name" => "broken", "error" => "missing_project_path", "tasks" => [] } ]
      )
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(
          mode: :new_idea,
          snapshot: snap,
          scope: 1,
          new_idea_buffer: "see [image1]",
          new_idea_cursor: 12,
          new_idea_attachments: [ attachment ],
          new_idea_staging_dir: staging_dir
        ),
        dispatch: @dispatch
      )

      @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED)

      assert_equal :new_idea, @model.hive_model.mode
      assert_equal "see [image1]", @model.hive_model.new_idea_buffer
      assert_equal [ attachment ], @model.hive_model.new_idea_attachments
      assert File.exist?(staging_path), "staged image must survive explicit-scope project failure"
      assert_match(/"broken".*missing project path/i, @model.hive_model.flash.to_s)
    end
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

  def test_rich_submit_logs_when_staging_cleanup_fails
    with_staged_image_attachment do |staging_dir, _staging_path, attachment|
      snap = Hive::Tui::Snapshot.from_payload(
        "generated_at" => "2026-05-13",
        "projects" => [ { "name" => "hive", "tasks" => [] } ]
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
      logs = []
      new_sentinel = Hive::Commands::New.instance_method(:call!)
      Hive::Commands::New.define_method(:call!) { nil }

      begin
        with_singleton_method_stub(Hive::Tui::Debug, :log, lambda { |channel, message|
          logs << [ channel, message ]
        }) do
          with_singleton_method_stub(Hive::Tui::ComposerStaging, :cleanup!, lambda { |_path, **_kwargs|
            raise Errno::EACCES, "denied"
          }) do
            capture_io { @model.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }
          end
        end
      ensure
        Hive::Commands::New.define_method(:call!, new_sentinel)
      end

      assert_equal :grid, @model.hive_model.mode
      assert_nil @model.hive_model.new_idea_staging_dir
      assert_equal "new_idea_staging", logs.dig(0, 0)
      assert_match(/ensure cleanup: Errno::EACCES/, logs.dig(0, 1).to_s)
    end
  end

  def test_open_summary_opens_summary_file_with_editor_takeover
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "7-finalize", "some-slug")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "summary.md"), "# Summary\n")
      row = make_task_row(
        action_key: "complete", stage: "7-finalize", marker: "complete", folder: folder
      )

      with_editor_env(visual: nil, editor: "fake-editor") do
        _, cmd = @model.update(Hive::Tui::Messages::OpenSummary.new(row: row))
        assert_kind_of Bubbletea::SequenceCommand, cmd
      end

      assert_match(/opening summary for some-slug in fake-editor/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_summary_foreground_callable_runs_editor_and_restores_terminal
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "7-finalize", "some-slug")
      FileUtils.mkdir_p(folder)
      summary = File.join(folder, "summary.md")
      File.write(summary, "# Summary\n")
      row = make_task_row(
        action_key: "complete", stage: "7-finalize", marker: "complete", folder: folder
      )
      calls = []
      captured_callable = nil
      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      @model.define_singleton_method(:run_editor) { |argv, path| calls << [ :editor, argv, path ] }
      @model.define_singleton_method(:clear_terminal_for_takeover) { calls << [ :clear ] }

      with_singleton_method_stub(Hive::Tui::Subprocess, :foreground_takeover_command, lambda { |callable|
        captured_callable = callable
        :foreground_cmd
      }) do
        model, cmd = @model.send(:open_summary, row)
        assert_equal :foreground_cmd, cmd
        assert_match(/opening summary for some-slug in fake-editor/, model.flash)
      end

      captured_callable.call
      assert_equal [ [ :editor, [ "fake-editor" ], summary ], [ :clear ] ], calls
    end
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

  # ---- RecoverReview → shared recovery coordinator ----

  def last_async_flash_text
    flash_msg = @messages.reverse.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    flash_msg&.text.to_s
  end

  def test_recover_review_submits_the_observed_row_and_renders_canonical_receipt
    folder = "/tmp/hive/recover-me"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "recover-me",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "phase" => "triage", "reason" => "merge_conflict", "pass" => "2" },
      suggested_command: nil
    )
    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

    call = @recovery_writer.calls.fetch(0)
    assert_same row, call.fetch(:row)
    assert_equal row.project_name, call.fetch(:project)
    assert_equal "tui", call.fetch(:requestor)

    sync_flash = @model.hive_model.flash.to_s
    assert_match(/Checking recovery/, sync_flash)
    assert_match(/REVIEW_ERROR/, sync_flash)
    assert_match(/phase=triage/, sync_flash)
    assert_match(/reason=merge_conflict/, sync_flash)
    assert_match(/pass=2/, sync_flash)

    final_flash = last_async_flash_text
    assert_equal "Recovery queued — request tui-test", final_flash
  end

  def test_recover_review_renders_a_blocked_coordinator_receipt
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "recover-me",
      stage: "6-review",
      folder: "/tmp/hive/recover-me",
      marker: "review_error",
      attrs: { "reason" => "merge_conflict", "pass" => "3" },
      suggested_command: nil
    )
    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "blocked",
        summary: "Recovery blocked — generation conflict; refresh status"
      )
    end

    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

    assert_equal 1, @recovery_writer.calls.size
    assert_equal(
      "Recovery blocked — generation conflict; refresh status",
      last_async_flash_text
    )
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

  def test_recover_review_stale_max_passes_hit_force_submits_to_coordinator
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
    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row, force: true))
    @model.wait_for_background_threads

    assert_equal 1, @recovery_writer.calls.size
    assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)
    assert_equal "Recovery queued — request tui-test", last_async_flash_text
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

  def test_recover_review_stale_with_incomplete_triage_pass_uses_coordinator
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
      @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      @model.wait_for_background_threads

      assert_equal 1, @recovery_writer.calls.size
      assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)

      final_flash = last_async_flash_text
      assert_equal "Recovery queued — request tui-test", final_flash
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

  def test_recover_review_stale_wall_clock_uses_coordinator_without_reviewer_files
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
      @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      @model.wait_for_background_threads

      assert_equal 1, @recovery_writer.calls.size
      assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)
      assert_equal "Recovery queued — request tui-test", last_async_flash_text
    end
  end

  def test_recover_review_renders_running_coordinator_receipt
    folder = "/tmp/hive/partial-failure"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "partial-failure",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "reason" => "merge_conflict", "pass" => "2" },
      suggested_command: nil
    )

    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "running",
        summary: "Agent running — request recovery-1; attempt attempt-1"
      )
    end

    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

    assert_equal "Agent running — request recovery-1; attempt attempt-1",
                 last_async_flash_text
  end

  def test_recover_review_renders_terminal_coordinator_receipt
    folder = "/tmp/hive/spawn-false"
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "spawn-false",
      stage: "6-review",
      folder: folder,
      marker: "review_error",
      attrs: { "reason" => "merge_conflict", "pass" => "2" },
      suggested_command: nil
    )
    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "terminal",
        summary: "Recovery terminal — attempt attempt-1; succeeded"
      )
    end

    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

    assert_equal "Recovery terminal — attempt attempt-1; succeeded",
                 last_async_flash_text
  end

  def test_recover_review_flashes_when_folder_missing
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "no-folder",
      stage: "6-review",
      folder: "",
      marker: "review_error",
      attrs: { "reason" => "merge_conflict" },
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

  def test_recover_review_surfaces_io_failure_from_coordinator_writer
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "io-fail",
      stage: "6-review",
      folder: "/tmp/hive/io-fail",
      marker: "review_error",
      attrs: { "reason" => "merge_conflict" },
      suggested_command: nil
    )
    @recovery_writer.handler = ->(**) { raise Errno::ENOENT, "no such file - queue" }
    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

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
      attrs: { "reason" => "merge_conflict" },
      suggested_command: nil
    )

    Thread.report_on_exception = false
    begin
      @recovery_writer.handler = ->(**) { raise NoMethodError, "undefined method `frob` for nil" }
      @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
      @model.wait_for_background_threads
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
      attrs: { "reason" => "merge_conflict", "pass" => "2" },
      suggested_command: nil
    )
    # Block the worker on a latch so the second Enter sees an
    # in-flight slot. Without the latch, the first worker can
    # finish and evict the slot before the second message arrives,
    # turning a real-life double-Enter race into an ordered pair.
    latch = Queue.new
    coordinator_calls = 0
    @recovery_writer.handler = lambda do |**|
      coordinator_calls += 1
      latch.pop # block until the test releases
      RecoveryReceipt.new(status: "queued", summary: "Recovery queued")
    end

    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    latch << :go
    @model.wait_for_background_threads

    assert_equal 1, coordinator_calls
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

  def test_recover_review_without_attrs_still_submits_complete_row
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
    @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
    @model.wait_for_background_threads

    assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)
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
      attrs: { "reason" => "merge_conflict", "zebra" => "z", "apple" => "a" },
      suggested_command: nil
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))
        @model.wait_for_background_threads
      end
    end

    flash = @model.hive_model.flash.to_s
    reason_idx = flash.index("reason=merge_conflict")
    apple_idx = flash.index("apple=a")
    zebra_idx = flash.index("zebra=z")
    refute_nil reason_idx
    refute_nil apple_idx
    refute_nil zebra_idx
    assert reason_idx < apple_idx, "known DETAIL_ATTRS keys must appear before extra keys"
    assert apple_idx < zebra_idx, "extra keys must be appended in sorted order"
  end

  # ---- RecoverError → shared recovery coordinator ----

  def test_recover_error_submits_observed_row_and_renders_canonical_receipt
    folder = "/tmp/hive/error-me"
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      slug: "error-me",
      stage: "3-plan",
      folder: folder,
      marker: "error",
      attrs: { "reason" => "exit_code", "exit_code" => "1", "marker_id" => "err-123" },
      suggested_command: nil
    )
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    call = @recovery_writer.calls.fetch(0)
    assert_same row, call.fetch(:row)
    assert_equal row.project_name, call.fetch(:project)
    assert_equal "tui", call.fetch(:requestor)

    sync_flash = @model.hive_model.flash.to_s
    assert_match(/Checking recovery/, sync_flash)
    assert_match(/ERROR/, sync_flash)
    assert_match(/reason=exit_code/, sync_flash)
    assert_match(/exit_code=1/, sync_flash)
    refute_match(/marker_id/, sync_flash)

    final_flash = last_async_flash_text
    assert_equal "Recovery queued — request tui-test", final_flash
  end

  def test_recover_error_forwards_legacy_observed_attrs_to_coordinator
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
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    forwarded = @recovery_writer.calls.fetch(0).fetch(:row)
    assert_equal({ "reason" => "exit_code", "exit_code" => "1" }, forwarded.attrs)
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
      stage: "8-finalize",
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
    assert_match(/no automatic recovery/i, @model.hive_model.flash)
    assert_match(/Open in agent/, @model.hive_model.flash,
                 "no-recipe refusal must nudge operator toward the manual fallback")
  end

  def test_open_red_status_detail_resolves_agent_label_from_task_project_config
    with_tmp_dir do |dir|
      slug = "red-detail-260525-aaaa"
      folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(dir, ".hive-state", "config.yml"), { "execute" => { "agent" => "codex" } }.to_yaml)
      File.write(File.join(folder, "task.md"), "# task\n<!-- ERROR -->\n")
      row = make_task_row(
        action_key: "error", action_label: "Error", slug: slug, stage: "4-execute",
        folder: folder, marker: "error", attrs: { "reason" => "exit_code" }, suggested_command: nil
      )

      with_env("HIVE_CODEX_BIN" => nil) do
        @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
      end

      assert_equal :red_status_detail, @model.hive_model.mode
      assert_equal "codex", @model.hive_model.red_status_detail_state.agent_label
      assert_same row, @model.hive_model.red_status_detail_state.row
    end
  end

  def test_open_red_status_detail_uses_fallback_agent_label_for_malformed_folder
    row = make_task_row(
      action_key: "error", action_label: "Error", slug: "bad-folder", stage: "4-execute",
      folder: "/tmp/not-a-hive-task", marker: "error", attrs: {}, suggested_command: nil
    )

    @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))

    assert_equal :red_status_detail, @model.hive_model.mode
    assert_equal Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK,
                 @model.hive_model.red_status_detail_state.agent_label
  end

  def test_red_status_autofix_from_detail_mode_closes_screen_on_recovery_success
    # Happy-path pin for plan Unit 4: a recoverable recover_review row
    # dispatched from :red_status_detail must flip the mode back to
    # :grid and clear red_status_detail_state — same close-on-dispatch
    # contract as the no-recipe refusal branch, with the synchronous
    # "clearing…" flash still surfacing.
    folder = "/tmp/hive/recover-detail"
    row = make_task_row(
      action_key: "recover_review", action_label: "Needs recovery",
      slug: "recover-detail", stage: "6-review", folder: folder,
      marker: "review_error", attrs: {}, suggested_command: nil
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
      dispatch: @dispatch,
      recovery_writer: @recovery_writer
    )

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RedStatusAutofix.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal :grid, @model.hive_model.mode
    assert_nil @model.hive_model.red_status_detail_state
    assert_match(/Checking recovery/, @model.hive_model.flash.to_s)
  end

  def test_close_red_status_detail_on_dispatch_reclamps_cursor_when_snapshot_visible
    row = make_task_row(
      action_key: "recover_review", action_label: "Needs recovery",
      slug: "visible-row", stage: "6-review", folder: "/tmp/hive/visible-row",
      marker: "review_error", attrs: {}, suggested_command: nil
    )
    snapshot = Hive::Tui::Snapshot.new(
      generated_at: "now",
      projects: [ Hive::Tui::Snapshot::ProjectView.new(
        name: "demo", path: "/tmp/demo", hive_state_path: "/tmp/demo/.hive-state",
        error: nil, rows: [ row ]
      ) ]
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
    starting = Hive::Tui::Model.initial.with(
      mode: :red_status_detail,
      red_status_detail_state: state,
      snapshot: snapshot,
      cursor: [ 0, 99 ]
    )

    closed, cmd = @model.send(:close_red_status_detail_on_dispatch, starting, nil)

    assert_nil cmd
    assert_equal :grid, closed.mode
    assert_nil closed.red_status_detail_state
    assert_equal [ 0, 0 ], closed.cursor
  end

  def test_close_red_status_detail_on_dispatch_passes_through_in_grid_mode
    # `dispatch_*_then_close_detail` wrappers also fire from grid mode
    # (RedStatusAutofix from grid Enter, OpenInAgent from grid `s`).
    # Pin the mode-guarded early-return so a grid-mode dispatch never
    # rewrites cursor / scope / filter through the close branch.
    row = make_task_row(
      action_key: "recover_review", action_label: "Needs recovery",
      slug: "grid-row", stage: "6-review", folder: "/tmp/hive/grid-row",
      marker: "review_error", attrs: {}, suggested_command: nil
    )
    starting = @model.hive_model.with(mode: :grid, cursor: [ 0, 0 ], scope: 0, filter: "foo")
    @model = Hive::Tui::BubbleModel.new(hive_model: starting, dispatch: @dispatch)

    with_run_quiet_stub(->(_argv) { [ 0, "", "" ] }) do
      with_dispatch_background_stub(->(_argv, **_kwargs) { nil }) do
        @model.update(Hive::Tui::Messages::RedStatusAutofix.new(row: row))
        @model.wait_for_background_threads
      end
    end

    assert_equal :grid, @model.hive_model.mode, "grid-mode autofix must leave mode unchanged"
    assert_nil @model.hive_model.red_status_detail_state
    assert_equal [ 0, 0 ], @model.hive_model.cursor, "cursor must be preserved on grid-mode pass-through"
    assert_equal 0, @model.hive_model.scope
    assert_equal "foo", @model.hive_model.filter
  end

  def test_red_status_autofix_from_detail_mode_closes_screen_on_no_recipe
    # Pressing Enter from :red_status_detail on a row with no automatic
    # recovery still closes the screen — the operator's gesture was
    # binary, leaving them stranded contradicts the plan's
    # "screen closes after the keypress" requirement. The Risk #3
    # mitigation flash names "Open in agent" so the next action is
    # obvious from the same flash. See plan Unit 4.
    row = make_task_row(
      action_key: "recover_execute",
      action_label: "Needs recovery",
      slug: "execute-stale-row",
      stage: "4-execute",
      marker: "execute_stale",
      attrs: {},
      suggested_command: nil
    )
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
      dispatch: @dispatch
    )

    @model.update(Hive::Tui::Messages::RedStatusAutofix.new(row: row))

    assert_equal :grid, @model.hive_model.mode
    assert_nil @model.hive_model.red_status_detail_state
    assert_match(/no automatic recovery/i, @model.hive_model.flash)
    assert_match(/Open in agent/, @model.hive_model.flash)
  end


  def test_red_status_autofix_routes_recover_review_error_and_fallback
    model = @model
    calls = []
    @model.define_singleton_method(:red_status_autofix_force?) { |_row| true }
    @model.define_singleton_method(:recover_review) do |row, force:|
      calls << [ :review, row.slug, force ]
      [ model.hive_model, nil ]
    end
    @model.define_singleton_method(:recover_error) do |row|
      calls << [ :error, row.slug ]
      [ model.hive_model, nil ]
    end

    review_row = make_task_row(action_key: "recover_review", slug: "review-me", marker: "review_stale")
    error_row = make_task_row(action_key: "error", slug: "error-me", marker: "error")
    fallback_row = make_task_row(action_key: "manual", slug: "manual-me", marker: "error")

    @model.send(:red_status_autofix, review_row)
    @model.send(:red_status_autofix, error_row)
    fallback_model, = @model.send(:red_status_autofix, fallback_row)

    assert_equal [ [ :review, "review-me", true ], [ :error, "error-me" ] ], calls
    assert_match(/no automatic recovery/, fallback_model.flash)
  end

  def test_red_status_autofix_retries_fix_status_check_failed_review_error
    calls = []
    @model.define_singleton_method(:recover_review) do |row, force:|
      calls << [ row.slug, force ]
      [ @hive_model, nil ]
    end
    row = make_task_row(
      action_key: "recover_review",
      action_label: "Needs recovery",
      slug: "status-check-failed",
      stage: "6-review",
      marker: "review_error",
      attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
      suggested_command: nil
    )

    model, cmd = @model.send(:red_status_autofix, row)

    assert_nil cmd
    assert_equal [ [ "status-check-failed", false ] ], calls
    refute_match(/no automatic recovery/, model.flash)
  end

  def test_red_status_autofix_retries_clean_exit_error
    calls = []
    @model.define_singleton_method(:recover_error) do |row|
      calls << row.slug
      [ @hive_model, nil ]
    end
    row = make_task_row(
      action_key: "error",
      action_label: "Error",
      slug: "clean-exit-failed",
      stage: "8-finalize",
      marker: "error",
      attrs: { "reason" => "ensure_clean_on_exit_failed" },
      suggested_command: nil
    )

    model, cmd = @model.send(:red_status_autofix, row)

    assert_nil cmd
    assert_equal [ "clean-exit-failed" ], calls
    refute_match(/no automatic recovery/, model.flash)
  end

  def test_red_status_autofix_refuses_shell_composed_diagnostic_retry
    row = make_task_row(action_key: "error", slug: "unsafe-retry", marker: "none").with(
      diagnostic: {
        "suggested_next_action" => {
          "kind" => "retry",
          "command" => "hive run unsafe-retry; echo bad"
        }
      }
    )

    model, = @model.send(:red_status_autofix, row)

    assert_match(/not directly dispatchable/, model.flash)
  end

  def test_red_status_autofix_reports_malformed_diagnostic_retry
    row = make_task_row(action_key: "error", slug: "bad-retry", marker: "none").with(
      diagnostic: {
        "suggested_next_action" => {
          "kind" => "retry",
          "command" => "hive run 'unterminated"
        }
      }
    )

    model, = @model.send(:red_status_autofix, row)

    assert_match(/diagnostic retry command is malformed/, model.flash)
  end


  def test_recover_error_renders_blocked_coordinator_receipt
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "error-me", stage: "3-plan", folder: "/tmp/hive/error-me",
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "blocked",
        summary: "Recovery blocked — generation conflict; refresh status"
      )
    end
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    assert_equal "Recovery blocked — generation conflict; refresh status",
                 last_async_flash_text
  end

  def test_recover_error_renders_unavailable_coordinator_receipt
    folder = "/tmp/hive/partial-failure"
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "partial-failure", stage: "3-plan", folder: folder,
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )

    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "unavailable",
        summary: "Current state unavailable — refresh status and inspect the recovery request"
      )
    end
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    assert_equal(
      "Current state unavailable — refresh status and inspect the recovery request",
      last_async_flash_text
    )
  end

  def test_recover_error_renders_terminal_coordinator_receipt
    folder = "/tmp/hive/error-spawn-false"
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "error-spawn-false", stage: "3-plan", folder: folder,
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(
        status: "terminal",
        summary: "Recovery terminal — attempt attempt-1; failed"
      )
    end
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    assert_equal "Recovery terminal — attempt attempt-1; failed",
                 last_async_flash_text
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

  def test_recover_error_submits_kill_class_code_when_reason_is_not_exit_code
    folder = "/tmp/hive/shutdown-kill"
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "shutdown-kill", stage: "3-plan", folder: folder,
      marker: "error", attrs: { "reason" => "shutdown", "exit_code" => "143" },
      suggested_command: nil
    )
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)
    assert_equal "Recovery queued — request tui-test", last_async_flash_text
  end

  def test_recover_error_surfaces_io_failure_from_coordinator_writer
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "io-fail", stage: "3-plan", folder: "/tmp/hive/io-fail",
      marker: "error", attrs: { "reason" => "exit_code", "exit_code" => "1" },
      suggested_command: nil
    )
    @recovery_writer.handler = ->(**) { raise Errno::ENOENT, "no such file - queue" }
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

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
      @recovery_writer.handler = ->(**) { raise NoMethodError, "undefined method `frob` for nil" }
      @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
      @model.wait_for_background_threads
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
    coordinator_calls = 0
    @recovery_writer.handler = lambda do |**|
      coordinator_calls += 1
      latch.pop
      RecoveryReceipt.new(status: "queued", summary: "Recovery queued")
    end

    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    latch << :go
    @model.wait_for_background_threads

    assert_equal 1, coordinator_calls
    assert_match(/already in progress/, @model.hive_model.flash.to_s,
                 "second Enter must flash an 'already in progress' refusal synchronously")
  end

  def test_recover_error_without_attrs_still_submits_complete_row
    row = make_task_row(
      action_key: "error", action_label: "Error",
      slug: "no-attrs", stage: "3-plan", folder: "/tmp/hive/no-attrs",
      marker: "error", attrs: {}, suggested_command: nil
    )
    @model.update(Hive::Tui::Messages::RecoverError.new(row: row))
    @model.wait_for_background_threads

    assert_same row, @recovery_writer.calls.fetch(0).fetch(:row)
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

  # ---- OpenIdeaPreview → full-screen info panel (read-only) ----

  def test_open_idea_preview_reads_inbox_common_fields_without_extra
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "1-inbox")
      write_idea_md(folder, original_text: "Build task from user note")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "1-inbox")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      state = @model.hive_model.info_panel_state
      assert_equal "some-slug", state.slug
      assert_equal "1-inbox", state.stage
      assert_equal "2026-05-20T00:00:00Z", state.created_at
      assert_equal "Build task from user note", state.original_text
      assert_equal File.expand_path(folder), state.folder_path
      assert_nil state.latest_log_path
      assert_nil state.stage_extra
    end
  end

  def test_open_idea_preview_reads_brainstorm_extra_and_latest_log_path
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "Brainstorm this")
      File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\nA1")
      older = make_log(root, name: "old.log", text: "old\n", mtime: Time.at(1_700_000_000))
      latest = make_log(root, name: "latest.log", text: "latest\n", mtime: Time.at(1_700_000_010))
      row = make_task_row(folder: folder, slug: "some-slug", stage: "2-brainstorm")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      state = @model.hive_model.info_panel_state
      assert_equal File.expand_path(latest), state.latest_log_path
      refute_equal File.expand_path(older), state.latest_log_path
      assert_equal "# Brainstorm\nA1", state.stage_extra
    end
  end

  def test_open_idea_preview_brainstorm_extra_missing_is_nil
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "Brainstorm this")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "2-brainstorm")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_nil @model.hive_model.info_panel_state.stage_extra
    end
  end

  def test_open_idea_preview_unknown_stage_has_no_extra
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "5-open-pr")
      write_idea_md(folder, original_text: "PR draft")
      File.write(File.join(folder, "brainstorm.md"), "# Brainstorm")
      File.write(File.join(folder, "plan.md"), "# Plan")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "5-open-pr")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_nil @model.hive_model.info_panel_state.stage_extra,
                 "unknown stages must fall through to the safe nil default"
    end
  end

  def test_open_idea_preview_reads_plan_extra
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "3-plan")
      write_idea_md(folder, original_text: "Plan this")
      File.write(File.join(folder, "plan.md"), "# Plan\nIU1")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "3-plan")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      state = @model.hive_model.info_panel_state
      assert_equal "3-plan", state.stage
      assert_equal "# Plan\nIU1", state.stage_extra
    end
  end

  def test_open_idea_preview_reads_execute_log_tail
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "4-execute")
      write_idea_md(folder, original_text: "Execute this")
      old_log = make_log(root, name: "execute-old.log", text: "old log\n", mtime: Time.at(1_700_000_000))
      long_prefix = "prefix-marker\n" + ("x" * (Hive::Tui::BubbleModel::INFO_PANEL_EXECUTE_TAIL_BYTES + 100))
      latest_log = make_log(
        root,
        name: "execute-latest.log",
        text: "#{long_prefix}\nlatest tail marker\n",
        mtime: Time.at(1_700_000_020)
      )
      row = make_task_row(folder: folder, slug: "some-slug", stage: "4-execute")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      state = @model.hive_model.info_panel_state
      assert_equal File.expand_path(latest_log), state.latest_log_path
      refute_equal File.expand_path(old_log), state.latest_log_path
      assert_includes state.stage_extra, "latest tail marker"
      refute_includes state.stage_extra, "prefix-marker"
    end
  end

  def test_open_idea_preview_execute_tail_filters_to_execute_prefix
    # 4-execute info-panel tail must select the latest `execute-*.log`
    # — a newer non-execute log (e.g. `plan-*.log`) shows up in
    # `latest_log_path` (the generic pointer) but is not tailed in the
    # `execute log` extra section.
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "4-execute")
      write_idea_md(folder, original_text: "Execute prefix test")
      execute_log = make_log(
        root,
        name: "execute-impl-old.log",
        text: "execute tail marker\n",
        mtime: Time.at(1_700_000_010)
      )
      newer_plan = make_log(
        root,
        name: "plan-newer.log",
        text: "plan tail marker\n",
        mtime: Time.at(1_700_000_020)
      )
      row = make_task_row(folder: folder, slug: "some-slug", stage: "4-execute")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      state = @model.hive_model.info_panel_state
      # `latest_log_path` still reports the absolute newest log, so the
      # operator sees the freshest pointer even when it isn't the
      # execute log they are about to tail.
      assert_equal File.expand_path(newer_plan), state.latest_log_path
      assert_includes state.stage_extra, "execute tail marker"
      refute_includes state.stage_extra, "plan tail marker"
      _ = execute_log
    end
  end

  def test_open_idea_preview_execute_without_log_has_nil_log_fields
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "4-execute")
      write_idea_md(folder, original_text: "Execute this")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "4-execute")

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      state = @model.hive_model.info_panel_state
      assert_nil state.latest_log_path
      assert_nil state.stage_extra
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
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/no idea\.md for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_flashes_when_original_text_missing
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      File.write(File.join(folder, "idea.md"), "---\nslug: some-slug\n---\n")
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/idea has no original_text for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_flashes_on_unreadable_idea_md
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      File.write(File.join(folder, "idea.md"), "---\noriginal_text: [broken\n---\n")
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :grid, @model.hive_model.mode
      assert_match(/could not read idea for some-slug/, @model.hive_model.flash.to_s)
    end
  end

  def test_open_idea_preview_unreadable_extra_opens_common_fields
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "Read common")
      extra_path = File.join(folder, "brainstorm.md")
      File.write(extra_path, "secret\n")
      row = make_task_row(folder: folder, slug: "some-slug", stage: "2-brainstorm")

      blocked = File.expand_path(extra_path)
      original_open = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, **kwargs, &block|
        raise Errno::EACCES if File.expand_path(path.to_s) == blocked

        original_open.call(path, *args, **kwargs, &block)
      end

      begin
        _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))
      ensure
        File.define_singleton_method(:open, original_open)
      end

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal "Read common", @model.hive_model.info_panel_state.original_text
      assert_nil @model.hive_model.info_panel_state.stage_extra
    end
  end

  def test_open_idea_preview_does_not_dispatch_or_mutate_files
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      idea_path = write_idea_md(folder, original_text: "Read only")
      extra_path = File.join(folder, "brainstorm.md")
      File.write(extra_path, "notes\n")
      log_path = make_log(root, text: "log\n")
      before_mtimes = [ idea_path, extra_path, log_path ].to_h { |path| [ path, File.mtime(path) ] }
      before_contents = [ idea_path, extra_path, log_path ].to_h { |path| [ path, File.read(path) ] }
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_empty @messages
      before_mtimes.each do |path, mtime|
        assert_equal mtime, File.mtime(path), "#{path} mtime changed"
      end
      before_contents.each do |path, content|
        assert_equal content, File.read(path), "#{path} content changed"
      end
    end
  end

  def test_open_idea_preview_truncates_oversized_original_text
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      original = "x" * (Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS + 20)
      write_idea_md(folder, original_text: original)
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS,
                   @model.hive_model.info_panel_state.original_text.length
    end
  end

  def test_open_idea_preview_created_at_is_propagated_from_frontmatter
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "Has timestamp", created_at: "2026-05-22T22:40:00Z")
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal "2026-05-22T22:40:00Z", @model.hive_model.info_panel_state.created_at
    end
  end

  def test_open_idea_preview_created_at_preserves_non_utc_timezone_verbatim
    # Pins the verbatim scalar path: a non-`Z` timestamp must survive
    # the YAML round-trip exactly as the operator typed it. Without
    # the `frontmatter_scalar` shortcut, a typed Time would normalize
    # to UTC and silently strip the `+03:00` offset.
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "TZ idea", created_at: "2026-05-22T22:40:00+03:00")
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      assert_equal "2026-05-22T22:40:00+03:00", @model.hive_model.info_panel_state.created_at
    end
  end

  def test_open_idea_preview_created_at_falls_back_to_typed_value
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      File.write(File.join(folder, "idea.md"), <<~MD)
        ---
        slug: some-slug
        created_at: |
          2026-05-22T22:40:00Z
        original_text: |
          Block scalar idea
        ---
      MD
      row = make_task_row(folder: folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil cmd
      # Trailing newline from the `|` block scalar must be stripped so the field grid does not wrap.
      assert_equal "2026-05-22T22:40:00Z", @model.hive_model.info_panel_state.created_at
    end
  end

  def test_frontmatter_scalar_preserves_hash_inside_quoted_value
    contents = <<~MD
      ---
      created_at: "2026-05-22 #note"
      ---
    MD

    assert_equal "2026-05-22 #note", @model.send(:frontmatter_scalar, contents, "created_at")
  end

  def test_frontmatter_scalar_strips_trailing_comment_after_whitespace
    contents = <<~MD
      ---
      created_at: 2026-05-22T22:40:00Z  # local capture
      ---
    MD

    assert_equal "2026-05-22T22:40:00Z", @model.send(:frontmatter_scalar, contents, "created_at")
  end

  def test_idea_preview_roundtrip_open_then_i_dismisses
    with_tmp_dir do |root|
      folder = make_task_folder(root, stage: "2-brainstorm")
      write_idea_md(folder, original_text: "Roundtrip idea")
      row = make_task_row(folder: folder)

      _, open_cmd = @model.update(Hive::Tui::Messages::OpenIdeaPreview.new(row: row))

      assert_nil open_cmd
      assert_equal :idea_preview, @model.hive_model.mode
      assert_equal "Roundtrip idea", @model.hive_model.info_panel_state.original_text

      _, dismiss_cmd = @model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ "i".ord ]))

      assert_nil dismiss_cmd
      assert_equal :grid, @model.hive_model.mode
      assert_nil @model.hive_model.info_panel_state
      assert_empty @messages
    end
  end

  # ---- OpenInAgent → configured agent foreground takeover ----

  def test_open_in_agent_marks_manual_steering_and_spawns_in_worktree_with_context_dirs
    with_manual_task_context do |_project_root, hive_state, _folder, state_file, worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")
      captured_argv = nil
      captured_chdir = nil
      captured_lookup_name = nil
      captured_lookup_cfg = nil

      with_agent_profile_lookup_stub(->(name, cfg:) {
        # Raise on an unexpected agent name so an accidental change to
        # the cfg.dig("execute", "agent") resolution surfaces as a stub
        # failure rather than a silent pass on the captured-arg assertion
        # below.
        raise "unexpected agent lookup: #{name.inspect}" unless name == "claude"

        captured_lookup_name = name
        captured_lookup_cfg = cfg
        profile
      }) do
        with_run_takeover_stub(->(argv, chdir: nil) {
          captured_argv = argv
          captured_chdir = chdir
          0
        }) do
          _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

          assert_kind_of Bubbletea::SequenceCommand, cmd
          assert_equal(
            [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
            cmd.commands.map(&:class)
          )
          assert_match(/steering manual-task in codex/, @model.hive_model.flash)

          marker = Hive::Markers.current(state_file)
          assert_equal :manual_steering, marker.name
          assert_equal "claude", marker.attrs["agent"]
          refute_empty marker.attrs["started_at"].to_s
          assert_equal true, profile.version_checked
          assert_equal true, profile.preflight_checked

          cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call
        end
      end

      assert_equal "claude", captured_lookup_name
      assert_equal "claude", captured_lookup_cfg.dig("execute", "agent")
      # Derive the expected context ordering from Hive::Stages::DIRS (the
      # SSOT) rather than a hard-coded list, so a future shuffle of the
      # stage order surfaces here even when the fixture happens to create
      # stages in the same order. The fixture preloads three stage dirs;
      # we filter DIRS to the ones present so the comparison is stable.
      present_stages = %w[1-inbox 3-plan 4-execute]
      expected_contexts = Hive::Stages::DIRS.select { |d| present_stages.include?(d) }.map do |stage|
        File.join(hive_state, "stages", stage, "manual-task")
      end
      expected_argv = [ "codex" ] + expected_contexts.flat_map { |path| [ "--add-dir", path ] }
      assert_equal expected_argv, captured_argv
      assert_equal worktree_path, captured_chdir
      assert_equal 1, @messages.length
      assert_kind_of Hive::Tui::Messages::AgentSteerExited, @messages.first
      assert_equal "manual-task", @messages.first.slug
      assert_equal worktree_path, @messages.first.worktree
      assert_equal 0, @messages.first.exit_code
    end
  end

  def test_open_in_agent_without_add_dir_flag_spawns_without_context_pairs_and_flashes_warning
    with_manual_task_context do |_project_root, _hive_state, _folder, _state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "pi", add_dir_flag: nil)
      captured_argv = nil

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        with_run_takeover_stub(->(argv, chdir: nil) { captured_argv = argv; 0 }) do
          _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))
          assert_kind_of Bubbletea::SequenceCommand, cmd
          assert_match(/no add-dir flag/, @model.hive_model.flash)

          cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call
        end
      end

      assert_equal [ "pi" ], captured_argv
    end
  end

  def test_open_in_agent_refuses_when_worktree_missing_without_flipping_marker
    with_manual_task_context(stage: "3-plan", worktree: false) do |_project_root, _hive_state, _folder, state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

        assert_nil cmd
        assert_match(/no worktree for manual-task/, @model.hive_model.flash)
        assert_equal :none, Hive::Markers.current(state_file).name
      end
    end
  end

  def test_open_in_agent_from_detail_mode_closes_screen_on_success
    # Happy-path pin for plan Unit 5: pressing `o` from
    # :red_status_detail on a healthy task (worktree present, profile
    # resolves) returns a non-nil takeover Cmd alongside a model whose
    # mode is :grid and red_status_detail_state cleared. The takeover
    # Cmd is preserved so the foreground suspend still fires; the
    # close-on-dispatch contract guarantees the operator lands back on
    # the grid after the agent exits.
    with_manual_task_context do |_project_root, _hive_state, _folder, _state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")
      state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
        dispatch: @dispatch
      )

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

        refute_nil cmd, "happy path must return a foreground-takeover Cmd"
        assert_equal :grid, @model.hive_model.mode
        assert_nil @model.hive_model.red_status_detail_state
      end
    end
  end

  def test_open_in_agent_from_detail_mode_closes_screen_on_refusal
    # Pressing `o` from :red_status_detail closes the screen even
    # when the refusal branch fires (no worktree) — the operator
    # should land back on the grid, not stay stranded on the stale
    # detail view. See plan Unit 5.
    with_manual_task_context(stage: "3-plan", worktree: false) do |_project_root, _hive_state, _folder, state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")
      state = Hive::Tui::Model::RedStatusDetailState.new(row: row)
      @model = Hive::Tui::BubbleModel.new(
        hive_model: Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state),
        dispatch: @dispatch
      )

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

        assert_nil cmd
        assert_equal :grid, @model.hive_model.mode
        assert_nil @model.hive_model.red_status_detail_state
        assert_match(/no worktree for manual-task/, @model.hive_model.flash)
        assert_equal :none, Hive::Markers.current(state_file).name
      end
    end
  end

  def test_open_in_agent_refuses_unknown_config_agent_without_flipping_marker
    config = { "execute" => { "agent" => "ghost" } }
    with_manual_task_context(config: config) do |_project_root, _hive_state, _folder, state_file, _worktree_path, row|
      _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

      assert_nil cmd
      assert_match(/ghost/, @model.hive_model.flash)
      assert_equal :none, Hive::Markers.current(state_file).name
    end
  end

  def test_open_in_agent_refuses_profile_preflight_failure_without_flipping_marker
    with_manual_task_context do |_project_root, _hive_state, _folder, state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")
      profile.define_singleton_method(:check_version!) { raise Hive::AgentError, "codex missing" }

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

        assert_nil cmd
        assert_match(/codex missing/, @model.hive_model.flash)
        assert_equal :none, Hive::Markers.current(state_file).name
      end
    end
  end

  # ---- AgentSteerExited → archived-manual move ----

  def test_agent_steer_exited_archives_folder_on_zero_exit
    with_manual_task_context do |_project_root, hive_state, folder, _state_file, worktree_path, row|
      message = Hive::Tui::Messages::AgentSteerExited.new(
        slug: row.slug,
        folder: folder,
        exit_code: 0,
        worktree: worktree_path
      )

      _, cmd = @model.update(message)

      target = File.join(hive_state, "stages", "archived-manual", row.slug)
      assert_nil cmd
      refute File.exist?(folder), "source stage folder must be moved out of active stages"
      assert File.directory?(target), "manual archive target must exist"
      assert_match(/archived manual-task/, @model.hive_model.flash)
      assert_match(/shipped/, @model.hive_model.flash)
    end
  end

  def test_agent_steer_exited_archives_folder_on_nonzero_exit
    with_manual_task_context(slug: "failed-manual-task") do |_project_root, hive_state, folder, _state_file, worktree_path, row|
      message = Hive::Tui::Messages::AgentSteerExited.new(
        slug: row.slug,
        folder: folder,
        exit_code: 130,
        worktree: worktree_path
      )

      @model.update(message)

      target = File.join(hive_state, "stages", "archived-manual", row.slug)
      assert File.directory?(target), "non-zero agent exits still archive the task"
      # Flash must name both the exit code AND the archive target so the
      # operator who just hit Ctrl-C has a breadcrumb back to where the
      # task landed — earlier the flash said "archived ... anyway" with
      # no path.
      assert_match(/agent exited 130/, @model.hive_model.flash)
      assert_match(/archived failed-manual-task → archived-manual\//, @model.hive_model.flash)
    end
  end

  def test_agent_steer_exited_uses_numeric_suffix_on_archive_collision
    with_manual_task_context do |_project_root, hive_state, folder, _state_file, worktree_path, row|
      archived_root = File.join(hive_state, "stages", "archived-manual")
      FileUtils.mkdir_p(File.join(archived_root, row.slug))

      message = Hive::Tui::Messages::AgentSteerExited.new(
        slug: row.slug,
        folder: folder,
        exit_code: 0,
        worktree: worktree_path
      )

      @model.update(message)

      assert File.directory?(File.join(archived_root, row.slug)), "existing archive must be preserved"
      assert File.directory?(File.join(archived_root, "#{row.slug}-2")), "collision must use -2 suffix"
      assert_match(/archived-manual\/manual-task-2/, @model.hive_model.flash)
      assert_match(/collision/, @model.hive_model.flash)
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

  def test_open_input_editor_plan_advance_reports_marker_race_during_finalize
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
        raise Hive::Tui::BubbleModel::MarkerRaceError, :complete
      end

      _, cmd = @model.update(Hive::Tui::Messages::OpenInputEditor.new(row: row))
      cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }.callable.call

      flash = @messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
      refute_nil flash, "expected a suppression flash on marker race"
      assert_match(/plan marker changed during edit \(complete\)/, flash.text)
      refute(@messages.any? { |m| m.is_a?(Hive::Tui::Messages::DispatchCommand) },
             "no DispatchCommand may be emitted when marker finalization races")
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

  def make_error_row(slug:, folder:, exit_code:, reason: "exit_code", marker_id: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo", stage: "6-review", slug: slug, folder: folder,
      state_file: nil, marker: "error",
      attrs: { "reason" => reason, "exit_code" => exit_code.to_s }.tap { |attrs| attrs["marker_id"] = marker_id if marker_id },
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

  def test_snapshot_with_kill_class_code_but_non_exit_code_reason_does_not_heal
    captured = stub_heal_capture(@model)
    row = make_error_row(
      slug: "shutdown", folder: "/x/.hive-state/stages/6-review/shutdown",
      exit_code: 143, reason: "shutdown"
    )
    snap = snapshot_with([ row ])
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    assert_empty captured,
                 "auto-heal is reserved for reason=exit_code signal kills; other reasons need RecoverError"
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

  def test_heal_marker_forwards_observed_marker_id_to_coordinator
    row = make_error_row(
      slug: "killed", folder: "/x/.hive-state/stages/4-execute/killed",
      exit_code: 143, marker_id: "kill-123"
    )

    @model.send(:heal_marker, row)

    forwarded = @recovery_writer.calls.fetch(0).fetch(:row)
    assert_equal "kill-123", forwarded.attrs.fetch("marker_id")
    assert_equal "exit_code", forwarded.attrs.fetch("reason")
    assert_equal "tui", @recovery_writer.calls.fetch(0).fetch(:requestor)
  end

  def test_heal_marker_forwards_observed_attrs_for_legacy_rows
    row = make_error_row(
      slug: "killed", folder: "/x/.hive-state/stages/4-execute/killed",
      exit_code: 143
    )

    @model.send(:heal_marker, row)

    assert_equal(
      { "reason" => "exit_code", "exit_code" => "143" },
      @recovery_writer.calls.fetch(0).fetch(:row).attrs
    )
  end

  def test_heal_marker_keeps_backoff_window_when_coordinator_blocks
    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/6-review/killed", exit_code: 143)
    cache = @model.instance_variable_get(:@healed_folders)
    cache[row.folder] = Time.now - (Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS + 1)
    logs = []
    before = Time.now

    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(status: "blocked", summary: "Recovery blocked — generation conflict")
    end
    with_singleton_method_stub(Hive::Tui::Debug, :log, lambda { |tag, message = nil|
      logs << [ tag, message ]
    }) do
      @model.send(:heal_marker, row)
    end

    assert cache.key?(row.folder)
    assert_operator cache[row.folder], :>=, before
    assert_equal "auto_heal", logs.dig(0, 0)
    assert_match(/Recovery blocked/, logs.dig(0, 1))
  end

  def test_heal_marker_keeps_backoff_window_when_coordinator_raises
    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/6-review/killed", exit_code: 143)
    cache = @model.instance_variable_get(:@healed_folders)
    cache[row.folder] = Time.now - (Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS + 1)
    logs = []
    before = Time.now

    @recovery_writer.handler = ->(**) { raise RuntimeError, "boom" }
    with_singleton_method_stub(Hive::Tui::Debug, :log, lambda { |tag, message = nil|
      logs << [ tag, message ]
    }) do
      @model.send(:heal_marker, row)
    end

    assert cache.key?(row.folder)
    assert_operator cache[row.folder], :>=, before
    assert_equal "auto_heal", logs.dig(0, 0)
    assert_match(/RuntimeError: boom/, logs.dig(0, 1))
  end

  def test_blocked_heal_attempt_throttles_retries_until_interval_elapses
    row = make_error_row(slug: "killed", folder: "/x/.hive-state/stages/6-review/killed", exit_code: 143)
    snap = snapshot_with([ row ])
    @recovery_writer.handler = lambda do |**|
      RecoveryReceipt.new(status: "blocked", summary: "Recovery blocked")
    end
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.wait_for_background_threads
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.wait_for_background_threads

    assert_equal 1, @recovery_writer.calls.size

    @model.instance_variable_get(:@healed_folders)[row.folder] =
      Time.now - (Hive::Tui::BubbleModel::HEAL_REPEAT_INTERVAL_SECONDS + 1)
    @model.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: snap))
    @model.wait_for_background_threads

    assert_equal 2, @recovery_writer.calls.size
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
        argv: %w[hive pr hello-world-test-260425-431f --project demo --from 8-finalize],
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

  def test_verb_status_zero_exit_is_silent
    # The previous `verb == "status"` special case (handled the
    # `hive status --diagnose --write` background spawn fired by the
    # removed [R] refresh-diagnosis binding) is gone. Replacement
    # behavior: status verb falls through to the standard zero-exit
    # short-circuit and emits no flash.
    @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "status", exit_code: 0))
    assert_nil @model.hive_model.flash,
               "zero-exit status verb must be silent (no diagnose-failure flash)"
  end

  def test_verb_status_nonzero_exit_falls_through_to_default_flash
    with_isolated_subprocess_log do |log_path|
      write_log_section(
        log_path,
        argv: %w[hive status --diagnose hello --write],
        stderr: "some unknown error nobody patterns against",
        exit_code: 1
      )

      @model.update(Hive::Tui::Messages::SubprocessExited.new(verb: "status", exit_code: 1))

      flash = @model.hive_model.flash.to_s
      assert_match(/exited 1/, flash, "non-zero status verb without specific diagnostic falls back to generic flash")
      assert_match(/tail/, flash)
    end
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

  def test_open_red_status_detail_captures_last_50_lines_from_latest_log
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "detail-tail-260523-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(task_folder, "logs")
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, "review-fix-pass02.log")
      File.write(log_path, (1..100).map { |i| "line-#{i}" }.join("\n") + "\n")

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "6-review", slug: slug,
        folder: task_folder, state_file: nil, marker: "review_error",
        attrs: { "pass" => "2" }, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil,
        action_key: "recover_review", action_label: "Needs recovery",
        suggested_command: nil, next_action: nil,
        diagnostic: { "summary" => "review failed", "marker_signature" => "sig" }
      )

      _, cmd = @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
      state = @model.hive_model.red_status_detail_state

      assert_nil cmd
      assert_equal :red_status_detail, @model.hive_model.mode
      assert_equal log_path, state.log_path
      assert_equal 50, state.log_lines.length
      assert_equal "line-51", state.log_lines.first
      assert_equal "line-100", state.log_lines.last
      assert_equal 0, state.log_scroll_offset
    end
  end

  def test_open_red_status_detail_omits_log_state_when_no_log_exists
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "detail-no-log-260523-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      FileUtils.mkdir_p(task_folder)

      row = Hive::Tui::Snapshot::Row.new(
        project_name: File.basename(project_root), stage: "6-review", slug: slug,
        folder: task_folder, state_file: nil, marker: "review_error",
        attrs: { "pass" => "2" }, mtime: nil, age_seconds: 0,
        claude_pid: nil, claude_pid_alive: nil,
        action_key: "recover_review", action_label: "Needs recovery",
        suggested_command: nil, next_action: nil,
        diagnostic: { "summary" => "review failed", "marker_signature" => "sig" }
      )

      @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
      state = @model.hive_model.red_status_detail_state

      assert_equal :red_status_detail, @model.hive_model.mode
      assert_nil state.log_path
      assert_equal [], state.log_lines
    end
  end

  # U4 unreadable-log branch: a `chmod 000` regression on the snapshot
  # path must collapse to an empty log panel (EACCES branch), not tear
  # the TUI down. The happy and no-log cases above don't cover this
  # rescue arm.
  def test_open_red_status_detail_handles_unreadable_log_file
    skip "skip-as-root: chmod 000 doesn't restrict root" if Process.uid.zero?
    require "tmpdir"
    Dir.mktmpdir do |project_root|
      slug = "detail-unreadable-260523-aaaa"
      task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      logs = File.join(task_folder, "logs")
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, "review-fix-pass02.log")
      File.write(log_path, "should not be readable\n")
      File.chmod(0, log_path)

      begin
        row = Hive::Tui::Snapshot::Row.new(
          project_name: File.basename(project_root), stage: "6-review", slug: slug,
          folder: task_folder, state_file: nil, marker: "review_error",
          attrs: { "pass" => "2" }, mtime: nil, age_seconds: 0,
          claude_pid: nil, claude_pid_alive: nil,
          action_key: "recover_review", action_label: "Needs recovery",
          suggested_command: nil, next_action: nil,
          diagnostic: { "summary" => "review failed", "marker_signature" => "sig" }
        )

        _, cmd = @model.update(Hive::Tui::Messages::OpenRedStatusDetail.new(row: row))
        state = @model.hive_model.red_status_detail_state

        assert_nil cmd, "unreadable log must not surface a Cmd; the rescue collapses to empty panel"
        assert_equal :red_status_detail, @model.hive_model.mode,
                     "TUI must still enter detail mode even when the log is unreadable"
        assert_nil state.log_path
        assert_equal [], state.log_lines
      ensure
        File.chmod(0o600, log_path) if File.exist?(log_path)
      end
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

  # ---- X-key drop focused task ----

  def test_drop_focused_task_dispatches_hive_drop_with_project_and_stage
    row = make_task_row(
      action_key: "ready_to_plan",
      slug: "drop-me",
      stage: "2-brainstorm",
      action_label: "Ready to plan"
    )
    calls = []
    before = Time.now

    with_dispatch_background_stub(->(argv, **_kwargs) { calls << argv; nil }) do
      @model.update(Hive::Tui::Messages::DropFocusedTask.new(row: row))
    end

    assert_equal [
      [ "hive", "drop", "drop-me", "--project", "demo", "--from", "2-brainstorm", "--json" ]
    ], calls
    assert_equal "dropping drop-me...", @model.hive_model.flash
    flash_set_at = @model.hive_model.flash_set_at
    refute_nil flash_set_at,
               "flash_set_at must be stamped so the 'dropping…' flash can age out"
    assert_kind_of Time, flash_set_at
    assert flash_set_at >= before,
           "flash_set_at must be recorded at/after the dispatch instant"
  end

  def test_drop_focused_task_without_row_flashes_selection_hint
    @model.update(Hive::Tui::Messages::DropFocusedTask.new(row: nil))

    assert_match(/select a task first/, @model.hive_model.flash.to_s)
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
  def test_stage66_recovery_helper_fails_closed_on_unreadable_review_files
    row = make_task_row(folder: "/tmp/hive/recover-edge", attrs: { "pass" => "1" })

    with_singleton_method_stub(Dir, :[], ->(_pattern) { raise Errno::EACCES, "denied" }) do
      refute @model.send(:retryable_incomplete_triage_pass?, row)
    end
  end

  def test_stage66_open_handlers_flash_for_missing_resources
    bad_row = make_task_row(action_key: "agent_running", slug: "bad-log", folder: "/tmp/not-a-task")
    _, cmd = @model.update(Hive::Tui::Messages::OpenLogTail.new(row: bad_row))

    assert_nil cmd
    assert_match(/log file gone/, @model.hive_model.flash.to_s)
  end

  def test_stage66_open_in_agent_refuses_stale_and_invalid_folders
    with_manual_task_context do |_project_root, _hive_state, folder, _state_file, _worktree_path, row|
      FileUtils.rm_rf(folder)

      _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

      assert_nil cmd
      assert_match(/no task folder for manual-task/, @model.hive_model.flash.to_s)
    end

    invalid_row = make_task_row(slug: "bad-agent", folder: "/tmp/not-a-task")
    _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: invalid_row))

    assert_nil cmd
    assert_match(/no task folder for bad-agent/, @model.hive_model.flash.to_s)
  end

  def test_stage66_open_in_agent_surfaces_lookup_and_marker_write_errors
    with_manual_task_context do |_project_root, _hive_state, _folder, _state_file, _worktree_path, row|
      with_agent_profile_lookup_stub(->(name, cfg:) { raise Hive::AgentProfiles::UnknownAgent, "unknown #{name}" }) do
        _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

        assert_nil cmd
        assert_match(/unknown agent in config: claude/, @model.hive_model.flash.to_s)
      end
    end

    with_manual_task_context do |_project_root, _hive_state, _folder, _state_file, _worktree_path, row|
      profile = ManualProfileStub.new(bin: "codex", add_dir_flag: "--add-dir")

      with_agent_profile_lookup_stub(->(_name, cfg:) { profile }) do
        with_singleton_method_stub(Hive::Markers, :set, ->(*_args, **_kwargs) { raise Errno::EACCES, "denied" }) do
          _, cmd = @model.update(Hive::Tui::Messages::OpenInAgent.new(row: row))

          assert_nil cmd
          assert_match(/steer failed for manual-task: EACCES/, @model.hive_model.flash.to_s)
        end
      end
    end
  end

  def test_stage66_archive_steer_error_paths_and_flash_variants
    invalid = Hive::Tui::Messages::AgentSteerExited.new(
      slug: "bad-folder", folder: "/tmp/not-a-task", exit_code: 1, worktree: "/tmp/worktree"
    )
    _, cmd = @model.update(invalid)

    assert_nil cmd
    assert_match(/manual archive failed for bad-folder: invalid task folder/, @model.hive_model.flash.to_s)

    with_manual_task_context(slug: "missing-manual") do |_project_root, _hive_state, folder, _state_file, worktree_path, row|
      FileUtils.rm_rf(folder)
      message = Hive::Tui::Messages::AgentSteerExited.new(
        slug: row.slug, folder: folder, exit_code: 1, worktree: worktree_path
      )

      @model.update(message)

      assert_match(/manual archive failed for missing-manual: ENOENT/, @model.hive_model.flash.to_s)
    end

    with_tmp_dir do |dir|
      archived_root = File.join(dir, "archived-manual")
      FileUtils.mkdir_p(archived_root)
      FileUtils.mkdir_p(File.join(archived_root, "manual-task"))
      (2..Hive::Tui::BubbleModel::MANUAL_ARCHIVE_SUFFIX_CEILING).each do |suffix|
        FileUtils.mkdir_p(File.join(archived_root, "manual-task-#{suffix}"))
      end

      assert_raises(Errno::EEXIST) do
        @model.send(:manual_archive_target, archived_root, "manual-task")
      end
    end

    assert_match(
      /agent binary not found.*archived manual-task/,
      @model.send(:manual_archive_flash, "manual-task", "/tmp/manual-task", 127, false)
    )
    assert_match(
      /archived-manual\/manual-task-2\//,
      @model.send(:manual_archive_flash, "manual-task", "/tmp/manual-task-2", 127, true)
    )
    assert_match(
      /agent exited 2.*manual-task-2\/ \(collision\)/,
      @model.send(:manual_archive_flash, "manual-task", "/tmp/manual-task-2", 2, true)
    )
  end

  def test_stage66_summary_paths_and_editor_error_flash
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "7-finalize", "summary-fallback")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "pr.md"), "# PR\n")
      row = make_task_row(action_key: "complete", slug: "summary-fallback", stage: "7-finalize", folder: folder)

      @model.define_singleton_method(:editor_argv) { [ "fake-editor" ] }
      _, cmd = @model.update(Hive::Tui::Messages::OpenSummary.new(row: row))

      assert_kind_of Bubbletea::SequenceCommand, cmd
      assert_match(/opening summary for summary-fallback in fake-editor/, @model.hive_model.flash.to_s)
    end

    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "7-finalize", "summary-error")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "summary.md"), "# Summary\n")
      row = make_task_row(action_key: "complete", slug: "summary-error", stage: "7-finalize", folder: folder)

      @model.define_singleton_method(:editor_argv) { raise ArgumentError, "empty editor" }
      _, cmd = @model.update(Hive::Tui::Messages::OpenSummary.new(row: row))

      assert_nil cmd
      assert_match(/editor command invalid: empty editor/, @model.hive_model.flash.to_s)
    end
  end

  def test_stage66_review_stale_and_review_file_helpers_cover_rescues
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      File.write(File.join(dir, "reviews", "escalations-04.md"), "## High\n- [ ] finding\n")
      row = make_task_row(
        action_key: "recover_review", slug: "stale-review", stage: "6-review",
        folder: dir, marker: "review_stale", attrs: { "pass" => "4" }, suggested_command: nil
      )

      @model.define_singleton_method(:editor_argv) { raise ArgumentError, "empty editor" }
      _, cmd = @model.update(Hive::Tui::Messages::RecoverReview.new(row: row))

      assert_nil cmd
      assert_match(/editor command invalid: empty editor/, @model.hive_model.flash.to_s)
    end

    with_singleton_method_stub(File, :readlines, ->(_path) { raise Errno::EACCES, "denied" }) do
      refute @model.send(:file_has_unchecked_finding?, "/tmp/review.md")
    end
  end

  def test_stage66_marker_terminal_and_file_helpers_cover_error_paths
    race = Hive::Tui::BubbleModel::MarkerRaceError.new(:complete)
    assert_equal :complete, race.observed
    assert_match(/expected :waiting, observed :complete/, race.message)

    with_tmp_dir do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# Plan\n<!-- COMPLETE -->\n")
      row = make_task_row(slug: "plan-race", state_file: state_file)

      assert_raises(Hive::Tui::BubbleModel::MarkerRaceError) do
        @model.send(:finalize_plan_marker, row)
      end
    end

    with_singleton_method_stub(Hive::Markers, :current, ->(_path) { raise Errno::EACCES, "denied" }) do
      refute @model.send(:marker_still_open_for_input?, "/tmp/state.md")
    end

    assert_nil @model.send(:file_mtime, "/tmp/does-not-exist-for-hive-test")

    original_stdout = $stdout
    writes = []
    fake_stdout = Object.new
    fake_stdout.define_singleton_method(:tty?) { true }
    fake_stdout.define_singleton_method(:write) { |text| writes << text }
    fake_stdout.define_singleton_method(:flush) { nil }
    $stdout = fake_stdout
    @model.send(:clear_terminal_for_takeover)
    assert_equal [ "\e[2J\e[H" ], writes

    fake_stdout.define_singleton_method(:flush) { raise Errno::EPIPE, "closed" }
    @model.send(:clear_terminal_for_takeover)
  ensure
    $stdout = original_stdout if original_stdout
  end

  def test_stage66_log_tail_helper_wraps_tail_state
    tail = Struct.new(:path) do
      def lines(_count)
        [ "raw log\n" ]
      end
    end.new("/tmp/hive.log")
    wrapper = Hive::Tui::BubbleModel::LogTailContext.new(tail: tail, claude_pid_alive: true)

    assert_equal "/tmp/hive.log", wrapper.path
    assert_equal [ "raw log\n" ], wrapper.lines(1)
  end

  def test_stage66_attachment_and_scope_helpers_cover_defensive_paths
    attachment = Hive::Tui::Model::Attachment.new(label: "image1", staging_path: "/tmp/missing-image.png", ext: "png")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(new_idea_attachments: [ attachment ]),
      dispatch: @dispatch
    )

    with_singleton_method_stub(File, :exist?, ->(_path) { raise Errno::ENAMETOOLONG, "too long" }) do
      assert_equal [ "image1" ], @model.send(:rich_new_idea_broken_labels, "see [image1]")
    end

    duplicate = Hive::Tui::Model::Attachment.new(label: "image1", staging_path: "/tmp/other.png", ext: "png")
    @model = Hive::Tui::BubbleModel.new(
      hive_model: @model.hive_model.with(new_idea_attachments: [ attachment, duplicate ]),
      dispatch: @dispatch
    )
    error = assert_raises(Hive::Error) { @model.send(:attachments_by_label) }
    assert_match(/duplicate attachment labels: image1/, error.message)

    project = Struct.new(:name).new("beta")
    snapshot = Struct.new(:projects).new([ project ])
    model = Hive::Tui::Model.initial.with(scope: 1, snapshot: snapshot)
    assert_equal "beta", @model.send(:scope_label_for, model)

    model = Hive::Tui::Model.initial.with(scope: 2, snapshot: snapshot)
    assert_equal "2", @model.send(:scope_label_for, model)
  end
end
