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

  # ---- DispatchCommand → takeover_command wrapping ----

  def test_dispatch_command_message_returns_takeover_command
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo", "hi" ], verb: "hi")
    _, cmd = @model.update(msg)
    assert_kind_of Bubbletea::ExecCommand, cmd,
      "DispatchCommand must turn into an ExecCommand the runner can execute"
  end

  # ---- Late-binding dispatch (so App.run_charm can wire runner.method(:send)) ----

  def test_dispatch_setter_replaces_callable
    new_dispatch = ->(_m) { }
    @model.dispatch = new_dispatch
    # Any subsequent takeover_command construction should now embed the
    # new dispatch. Smoke check: the call doesn't raise.
    msg = Hive::Tui::Messages::DispatchCommand.new(argv: [ "echo" ], verb: nil)
    _, cmd = @model.update(msg)
    assert_kind_of Bubbletea::ExecCommand, cmd
  end
end
