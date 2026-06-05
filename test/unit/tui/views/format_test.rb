require "test_helper"
require "hive/tui/views/format"

# Hive::Tui::Views::Format is the single source of truth for the
# cell-aware string helpers (display_width/take_cells/ljust_cells/
# rjust_cells/truncate) shared across panes. Exercising them directly
# here localises regressions to the helper instead of surfacing them
# as downstream pane-rendering assertions.
class HiveTuiViewsFormatTest < Minitest::Test
  Format = Hive::Tui::Views::Format

  def test_truncate_wide_characters_respects_cell_width
    # Each CJK glyph is 2 cells wide; a naive code-unit slice would keep
    # too many characters and overflow the column. With the ellipsis
    # reserving one cell, the result must still fit within max_width.
    result = Format.truncate("日本語テスト", 5)

    assert Format.display_width(result) <= 5,
           "truncated wide string must fit in 5 cells, got width " \
           "#{Format.display_width(result)} for #{result.inspect}"
    assert result.end_with?("…"), "truncation past the limit appends an ellipsis"
    assert_equal "日本…", result,
                 "two full clusters (4 cells) plus the ellipsis fills exactly 5 cells"
  end

  def test_truncate_sub_two_width_hard_cuts_without_ellipsis
    # max_width < 2 leaves no room for the ellipsis suffix, so the
    # branch falls back to a hard cut of whole cells.
    assert_equal "a", Format.truncate("abc", 1)
  end

  def test_rjust_cells_right_pads_to_width
    assert_equal "  ab", Format.rjust_cells("ab", 4),
                 "rjust_cells pads on the left so content is right-aligned"
  end

  def test_ljust_cells_truncates_wide_overflow_to_exact_cell_width
    # "日本" is 4 cells; padded to 3 it must truncate (not overflow) and
    # the result must occupy exactly 3 cells. A naive String#ljust would
    # measure code units and leave a 4-cell string, shifting the column.
    result = Format.ljust_cells("日本", 3)

    assert_equal 3, Format.display_width(result),
                 "ljust_cells must clamp wide content to exactly 3 cells, got " \
                 "#{Format.display_width(result)} for #{result.inspect}"
  end

  def test_rjust_cells_truncates_wide_overflow_to_exact_cell_width
    result = Format.rjust_cells("日本", 3)

    assert_equal 3, Format.display_width(result),
                 "rjust_cells must clamp wide content to exactly 3 cells, got " \
                 "#{Format.display_width(result)} for #{result.inspect}"
  end

  def test_just_cells_clamp_to_empty_at_non_positive_width
    # The `[width - display_width, 0].max` guard prevents negative pad
    # counts; at width <= 0 there is no content and no padding.
    assert_equal "", Format.ljust_cells("ab", 0)
    assert_equal "", Format.rjust_cells("ab", 0)
    assert_equal "", Format.ljust_cells("ab", -3)
  end
end
