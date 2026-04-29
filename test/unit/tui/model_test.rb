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
    assert_nil model.flash
    assert_nil model.flash_set_at
    assert_nil model.triage_state
    assert_nil model.tail_state
    assert_nil model.last_error
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

  def test_model_carries_all_documented_fields
    # Schema-pinning test: catch accidental field renames or removals.
    expected = %i[mode snapshot cursor filter filter_buffer scope flash flash_set_at
                  triage_state tail_state cols rows last_error]
    assert_equal expected, Hive::Tui::Model.members
  end
end
