require "test_helper"
require "hive/tui/paste_aware_runner"
require "hive/tui/bubble_model"
require "hive/tui/model"

# Pinned unit tests for the load-bearing decoder-reset latch on
# PasteAwareRunner. Without these the orphan-paste fix could silently
# regress: a flipped comparison or a lost membership check would only
# surface as user-visible misbehavior (paste from prompt N leaking into
# prompt N+1), with no failing test pointing at the cause.
class HiveTuiPasteAwareRunnerTest < Minitest::Test
  include HiveTestHelper

  # Build a runner that bypasses Bubbletea::Runner#run (which tries to
  # initialize a real terminal). We only exercise the latch logic; the
  # runtime hooks are exercised end-to-end by the e2e tmux suite.
  def runner_for(initial_mode:)
    bubble = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(mode: initial_mode)
    )
    runner = Hive::Tui::PasteAwareRunner.new(bubble)
    [ runner, bubble ]
  end

  def set_mode(bubble, mode)
    bubble.instance_variable_set(:@hive_model, bubble.hive_model.with(mode: mode))
  end

  def test_reset_fires_on_transition_out_of_new_idea
    runner, bubble = runner_for(initial_mode: :new_idea)
    # Simulate a half-finished paste held in the decoder.
    runner.input_decoder.drain("\e[200~hello")
    assert_equal "hello", runner.input_decoder.instance_variable_get(:@paste_buffer)

    # First call — primes @last_editable_mode = :new_idea.
    runner.__send__(:reset_decoder_on_cancel)
    assert_equal "hello", runner.input_decoder.instance_variable_get(:@paste_buffer),
                 "no transition yet — decoder must not reset"

    # Mode flips to :grid (Esc cancel). Second call observes the
    # transition and triggers reset.
    set_mode(bubble, :grid)
    runner.__send__(:reset_decoder_on_cancel)
    assert_predicate runner.input_decoder.instance_variable_get(:@paste_buffer), :empty?,
                 "decoder must reset on transition out of :new_idea"
    refute runner.input_decoder.instance_variable_get(:@in_paste),
           "@in_paste must clear on cancel-transition"
  end

  def test_reset_fires_on_new_idea_to_filter_transition
    # Both modes are editable; the latch must still fire so a paste
    # held during :new_idea cannot leak into the next mode's filter
    # buffer. This is the case the literal "transitioned out of an
    # editable mode" reading would miss.
    runner, bubble = runner_for(initial_mode: :new_idea)
    runner.input_decoder.drain("\e[200~secrets")
    runner.__send__(:reset_decoder_on_cancel) # prime latch

    set_mode(bubble, :filter)
    runner.__send__(:reset_decoder_on_cancel)
    assert_predicate runner.input_decoder.instance_variable_get(:@paste_buffer), :empty?,
                 "decoder must reset on :new_idea → :filter (cross-editable transition)"
  end

  def test_reset_does_not_fire_on_grid_to_grid
    # No editable mode entered — there's nothing to reset, and a
    # spurious reset would erase pending escape state mid-keystroke.
    runner, _bubble = runner_for(initial_mode: :grid)
    runner.input_decoder.drain("\e[")
    runner.__send__(:reset_decoder_on_cancel)
    runner.__send__(:reset_decoder_on_cancel)
    assert_equal "\e[", runner.input_decoder.instance_variable_get(:@pending),
                 "decoder must not reset when no editable mode was entered"
  end

  def test_reset_does_not_fire_on_new_idea_to_new_idea
    # User reopened the prompt without leaving — nothing to drop.
    runner, _bubble = runner_for(initial_mode: :new_idea)
    runner.input_decoder.drain("\e[200~draft")
    runner.__send__(:reset_decoder_on_cancel)
    runner.__send__(:reset_decoder_on_cancel)
    assert_equal "draft", runner.input_decoder.instance_variable_get(:@paste_buffer),
                 "no transition — decoder must not reset"
  end

  def test_reset_idempotent_across_multiple_grid_iterations
    # Once reset has fired on :new_idea → :grid, subsequent :grid
    # iterations must not keep resetting (the latch's @last_editable_mode
    # should clear so the runner doesn't churn).
    runner, bubble = runner_for(initial_mode: :new_idea)
    runner.__send__(:reset_decoder_on_cancel) # prime
    set_mode(bubble, :grid)
    runner.__send__(:reset_decoder_on_cancel) # fires reset
    runner.input_decoder.drain("\e[")     # decoder accumulates legitimate pending state
    runner.__send__(:reset_decoder_on_cancel) # must NOT reset again
    assert_equal "\e[", runner.input_decoder.instance_variable_get(:@pending),
                 "latch must not re-fire on subsequent :grid → :grid"
  end

  def test_foreground_takeover_sequence_suppresses_render_until_sequence_finishes
    runner, = runner_for(initial_mode: :grid)
    runner.instance_variable_set(:@running, true)
    observed = []
    commands = [
      Bubbletea.exit_alt_screen,
      Bubbletea.exec(-> {}),
      Bubbletea.enter_alt_screen
    ]

    runner.define_singleton_method(:execute_command_sync) do |cmd|
      observed << [ cmd.class, instance_variable_get(:@suppress_render_for_foreground_takeover) ]
    end

    runner.__send__(:execute_sequence_sync, commands)

    assert_equal(
      [
        [ Bubbletea::ExitAltScreenCommand, true ],
        [ Bubbletea::ExecCommand, true ],
        [ Bubbletea::EnterAltScreenCommand, true ]
      ],
      observed,
      "rendering must stay suppressed across exit-alt-screen, editor exec, and re-entry"
    )
    refute runner.instance_variable_get(:@suppress_render_for_foreground_takeover),
           "render suppression must clear after the foreground takeover sequence"
  end

  def test_render_is_noop_while_foreground_takeover_is_suppressed
    runner, = runner_for(initial_mode: :grid)
    runner.instance_variable_set(:@renderer_id, 1)
    fake_program = Object.new
    fake_program.define_singleton_method(:render) { |_renderer_id, _view| raise "rendered during takeover" }
    runner.instance_variable_set(:@program, fake_program)
    runner.instance_variable_set(:@suppress_render_for_foreground_takeover, true)

    assert_nil runner.__send__(:render)
  end
end
