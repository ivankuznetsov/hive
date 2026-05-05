require "test_helper"
require "hive/tui/model"

# Hive::Tui::Model is the unified MVU state record. These tests pin
# the data shape, immutability, and the flash-active TTL helper.
class HiveTuiModelTest < Minitest::Test
  include HiveTestHelper

  def test_initial_returns_grid_mode_with_zero_cursor
    model = Hive::Tui::Model.initial
    assert_equal :grid, model.mode
    assert_equal [ 0, 0 ], model.cursor
  end

  def test_initial_clears_optional_fields
    model = Hive::Tui::Model.initial
    assert_nil model.snapshot
    assert_nil model.filter
    assert_equal "", model.filter_buffer
    assert_equal 0, model.scope
    assert_equal "", model.new_idea_buffer
    assert_equal 0, model.new_idea_cursor
    assert_nil model.flash
    assert_nil model.flash_set_at
    assert_nil model.triage_state
    assert_nil model.tail_state
    assert_nil model.last_error
  end

  def test_initial_pane_focus_defaults_to_right
    # v2 two-pane layout: :right preserves v1 muscle memory where verb
    # keys and Enter operate on the highlighted task without first
    # Tab'ing into the task pane.
    model = Hive::Tui::Model.initial
    assert_equal :right, model.pane_focus
  end

  def test_initial_accepts_terminal_dimensions
    model = Hive::Tui::Model.initial(cols: 120, rows: 40)
    assert_equal 120, model.cols
    assert_equal 40, model.rows
  end

  def test_initial_uses_safe_defaults_for_terminal_dimensions
    # Pre-WindowSized state: cols/rows must have non-nil defaults so
    # views can lay out without a nil-guard everywhere.
    model = Hive::Tui::Model.initial
    assert_equal 80, model.cols
    assert_equal 24, model.rows
  end

  def test_with_returns_new_instance_with_overridden_field
    a = Hive::Tui::Model.initial
    b = a.with(scope: 2)
    refute_same a, b, "#with must return a new Model, never mutate"
    assert_equal 0, a.scope
    assert_equal 2, b.scope
  end

  def test_model_is_immutable
    # Data.define records freeze themselves. Verify reassignment raises.
    model = Hive::Tui::Model.initial
    assert model.frozen?
  end

  def test_flash_active_when_within_ttl
    set_at = Time.now - 1.0
    model = Hive::Tui::Model.initial.with(flash: "hello", flash_set_at: set_at)
    assert model.flash_active?(now: Time.now), "flash 1s old should be active under default 5s TTL"
  end

  def test_flash_inactive_when_past_ttl
    set_at = Time.now - 10.0
    model = Hive::Tui::Model.initial.with(flash: "hello", flash_set_at: set_at)
    refute model.flash_active?(now: Time.now), "flash 10s old should be inactive under default 5s TTL"
  end

  def test_flash_inactive_when_no_flash_set
    model = Hive::Tui::Model.initial
    refute model.flash_active?, "default Model has no flash; flash_active? must be false"
  end

  def test_flash_inactive_when_flash_set_at_is_nil
    # Defensive check: if the flash field is set but timestamp is nil
    # (e.g., direct #with that bypasses the dispatch path), treat as
    # inactive rather than raising.
    model = Hive::Tui::Model.initial.with(flash: "hello", flash_set_at: nil)
    refute model.flash_active?
  end

  def test_flash_ttl_is_overridable_for_tests
    set_at = Time.now - 3.0
    model = Hive::Tui::Model.initial.with(flash: "hello", flash_set_at: set_at)
    assert model.flash_active?(ttl: 10.0), "should still be active under a 10s TTL"
    refute model.flash_active?(ttl: 1.0), "should be inactive under a 1s TTL"
  end

  def test_default_flash_ttl_constant_is_5_seconds
    # Pinning the operator-facing TTL — match the curses GridState
    # behavior that operators dogfooded against in v1.
    assert_equal 5.0, Hive::Tui::Model::DEFAULT_FLASH_TTL_SECONDS
  end

  def test_new_idea_buffer_cap_is_positive
    assert_operator Hive::Tui::Model::NEW_IDEA_BUFFER_MAX_CHARS, :>, 0
  end

  def test_model_carries_all_documented_fields
    # Schema-pinning test: catch accidental field renames or removals.
    expected = %i[mode snapshot cursor filter filter_buffer scope pane_focus new_idea_buffer new_idea_cursor
                  flash flash_set_at triage_state tail_state cols rows last_error]
    assert_equal expected, Hive::Tui::Model.members
  end

  def test_pane_focus_can_be_overridden_via_with
    a = Hive::Tui::Model.initial
    b = a.with(pane_focus: :left)
    assert_equal :right, a.pane_focus
    assert_equal :left, b.pane_focus
    refute_same a, b
  end

  def test_new_idea_buffer_can_be_overridden_via_with
    a = Hive::Tui::Model.initial
    b = a.with(new_idea_buffer: "rss feeds")
    assert_equal "", a.new_idea_buffer
    assert_equal "rss feeds", b.new_idea_buffer
  end

  def test_new_idea_cursor_can_be_overridden_via_with
    a = Hive::Tui::Model.initial
    b = a.with(new_idea_buffer: "rss feeds", new_idea_cursor: 3)
    assert_equal 0, a.new_idea_cursor
    assert_equal 3, b.new_idea_cursor
  end
end
