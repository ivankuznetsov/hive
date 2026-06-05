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
end
