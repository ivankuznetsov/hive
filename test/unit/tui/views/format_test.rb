require "test_helper"
require "hive/tui/views/format"

# Direct unit coverage for the cell-accounting primitives that back every
# column-fitted TUI surface. The overflow these guard against: a
# double-width grapheme (CJK/emoji) landing on an odd remaining column must
# be DROPPED, never partially rendered into a cell it does not fit — that is
# the boundary `tasks_pane_test` only exercised indirectly via icon columns.
class HiveTuiViewsFormatTest < Minitest::Test
  Format = Hive::Tui::Views::Format

  WIDE = "世界世界".freeze # each grapheme is 2 terminal cells (display width 8)

  def test_take_cells_never_exceeds_max_width_for_wide_graphemes
    (0..10).each do |max|
      result = Format.take_cells(WIDE, max)
      assert_operator Format.display_width(result), :<=, max,
                      "take_cells(#{WIDE.inspect}, #{max}) overflowed its cell budget"
    end
  end

  def test_take_cells_drops_a_wide_grapheme_that_lands_on_an_odd_column
    # One narrow char then a double-width one, budget 2: the wide grapheme
    # cannot fit the single remaining cell, so it is dropped rather than
    # overflowing to width 3.
    result = Format.take_cells("a世", 2)
    assert_equal "a", result
    assert_equal 1, Format.display_width(result)
  end

  def test_truncate_returns_string_unchanged_when_it_fits
    assert_equal "ab", Format.truncate("ab", 5)
    assert_equal WIDE, Format.truncate(WIDE, 8)
  end

  def test_truncate_appends_ellipsis_and_respects_cell_budget
    result = Format.truncate(WIDE, 5)
    assert result.end_with?("…"), "truncation must append an ellipsis"
    assert_operator Format.display_width(result), :<=, 5,
                    "ellipsised result must still fit the cell budget"
  end

  def test_truncate_max_width_one_against_leading_double_width_yields_empty
    # max_width 1 has no room for even one double-width grapheme, and < 2
    # means no ellipsis — the hard cut produces an empty string.
    assert_equal "", Format.truncate(WIDE, 1)
  end

  def test_truncate_max_width_one_keeps_a_single_narrow_cell
    assert_equal "a", Format.truncate("ab", 1)
  end

  def test_truncate_non_positive_width_is_empty
    assert_equal "", Format.truncate(WIDE, 0)
    assert_equal "", Format.truncate("ab", -3)
  end

  def test_ljust_cells_pads_wide_label_to_exact_cell_width
    padded = Format.ljust_cells("世", 5)
    assert_equal 5, Format.display_width(padded),
                 "ljust_cells must pad to the exact terminal-cell width"
    assert padded.start_with?("世")
  end

  def test_rjust_cells_pads_wide_label_to_exact_cell_width
    padded = Format.rjust_cells("世", 5)
    assert_equal 5, Format.display_width(padded)
    assert padded.end_with?("世")
  end
end
