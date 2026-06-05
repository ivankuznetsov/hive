require "test_helper"
require "hive/tui/views/format"

# Direct unit coverage for the cell-aware truncation/padding primitives
# in Views::Format. The grapheme-boundary and `max_width < 2` hard-cut
# branches were previously only exercised indirectly through TasksPane
# render tests, so an off-by-one cell bug could survive a refactor. These
# tests pin the wide-char (CJK/emoji, 2 cells each) behaviour explicitly.
class HiveTuiViewsFormatTest < Minitest::Test
  Format = Hive::Tui::Views::Format

  # ---- truncate ----

  def test_truncate_returns_string_unchanged_when_it_fits
    assert_equal "abc", Format.truncate("abc", 5)
    assert_equal "abc", Format.truncate("abc", 3)
  end

  def test_truncate_appends_ellipsis_for_narrow_ascii
    # "abcdef" is 6 cells; into 4 → 3 chars + ellipsis (1 cell) == 4 cells.
    result = Format.truncate("abcdef", 4)
    assert_equal "abc…", result
    assert_equal 4, Format.display_width(result)
  end

  def test_truncate_keeps_wide_char_string_that_exactly_fills_width
    # A single emoji is 2 cells; at max_width 2 it fits verbatim.
    assert_equal "🤖", Format.truncate("🤖", 2)
  end

  def test_truncate_at_wide_boundary_does_not_overflow_the_cell_budget
    # "🤖🤖" is 4 cells; into 3 → take 2 cells (one emoji) + ellipsis.
    result = Format.truncate("🤖🤖", 3)
    assert_equal "🤖…", result
    assert_equal 3, Format.display_width(result),
                 "ellipsis at a wide-char boundary must not exceed the width budget"
  end

  def test_truncate_hard_cuts_without_ellipsis_when_width_below_two
    # max_width < 2 leaves no room for the ellipsis suffix; a 2-cell
    # glyph can't fit in 1 cell, so the result is empty.
    assert_equal "", Format.truncate("🤖", 1)
  end

  def test_truncate_hard_cut_keeps_a_fitting_narrow_glyph
    assert_equal "a", Format.truncate("ab", 1)
  end

  def test_truncate_returns_empty_for_nonpositive_width
    assert_equal "", Format.truncate("anything", 0)
    assert_equal "", Format.truncate("anything", -3)
  end

  def test_truncate_handles_nil_label
    assert_equal "", Format.truncate(nil, 4)
  end

  # ---- take_cells ----

  def test_take_cells_stops_before_exceeding_the_budget
    # a(1) + 🤖(2) == 3 cells; the trailing b(1) would exceed and is dropped.
    assert_equal "a🤖", Format.take_cells("a🤖b", 3)
  end

  def test_take_cells_drops_a_wide_glyph_that_would_overflow
    # Only 1 cell of budget: the 2-cell emoji cannot be taken.
    assert_equal "", Format.take_cells("🤖", 1)
  end

  # ---- ljust_cells / rjust_cells ----

  def test_ljust_cells_pads_wide_char_to_full_cell_width
    result = Format.ljust_cells("🤖", 4)
    assert_equal "🤖  ", result
    assert_equal 4, Format.display_width(result),
                 "wide-char label must be padded by display cells, not code units"
  end

  def test_rjust_cells_pads_wide_char_to_full_cell_width
    result = Format.rjust_cells("🤖", 4)
    assert_equal "  🤖", result
    assert_equal 4, Format.display_width(result)
  end

  def test_ljust_cells_truncates_before_padding_when_over_width
    result = Format.ljust_cells("🤖🤖", 3)
    assert_equal 3, Format.display_width(result),
                 "over-width wide-char labels must be truncated to the column, not over-pad"
  end
end
