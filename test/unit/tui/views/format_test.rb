require "test_helper"
require "hive/tui/views/format"

# Direct coverage for the public `Format.wrap` helper. Exercises its
# branches (empty guard, multi-line input, verbatim pass-through of
# already-fitting lines, narrow-width word-wrap, and the hard-split of an
# over-long single word) directly rather than only through overlay
# rendering.
class HiveTuiViewsFormatWrapTest < Minitest::Test
  Format = Hive::Tui::Views::Format

  def test_empty_string_yields_a_single_blank_line
    assert_equal [ "" ], Format.wrap("", 20)
  end

  def test_nil_is_coerced_to_a_single_blank_line
    assert_equal [ "" ], Format.wrap(nil, 20)
  end

  def test_short_line_passes_through_unwrapped
    assert_equal [ "hello world" ], Format.wrap("hello world", 20)
  end

  def test_multi_line_input_wraps_each_line_independently
    assert_equal [ "line one", "line two" ], Format.wrap("line one\nline two", 20)
  end

  def test_multi_line_input_preserves_blank_lines
    assert_equal [ "a", "", "b" ], Format.wrap("a\n\nb", 20)
  end

  def test_long_text_wraps_onto_multiple_rows
    rows = Format.wrap("the quick brown fox jumps", 12)

    assert_operator rows.length, :>, 1, "text wider than the width must wrap onto several rows"
    assert(rows.all? { |row| Format.display_width(row) <= 12 }, "no wrapped row may exceed the width")
  end

  def test_narrow_width_word_wraps_without_dropping_characters
    # Even at a narrow width the words wrap rather than getting
    # ellipsis-truncated — no characters are dropped.
    rows = Format.wrap("hello world", 8)

    assert_equal [ "hello", "world" ], rows
    assert(rows.none? { |row| row.include?("…") }, "narrow-width wrap must not ellipsis-truncate")
  end

  def test_over_long_single_word_is_hard_split_not_truncated
    rows = Format.wrap("supercalifragilistic", 12)

    assert_operator rows.length, :>, 1, "an unbreakable word wider than the width must split across rows"
    assert(rows.all? { |row| Format.display_width(row) <= 12 }, "no split row may exceed the width")
    assert(rows.none? { |row| row.include?("…") }, "a hard-split word must not be ellipsis-truncated")
    assert_equal "supercalifragilistic", rows.join, "the split rows must reconstruct the original word"
  end

  def test_wide_characters_are_measured_in_cells_not_codepoints
    # Each CJK glyph is two cells wide, so four of them fill a width of 8.
    rows = Format.wrap("一二三四五六", 8)

    assert(rows.all? { |row| Format.display_width(row) <= 8 }, "wide glyphs must respect the cell width")
  end

  def test_wide_glyph_word_wrap_respects_cells_above_truncate_threshold
    # Width 12 is past the `max_width <= 8` truncate early-return, so this
    # exercises the cell-aware word-wrap loop itself: six two-cell glyphs
    # (12 cells) plus a trailing word must spill onto multiple rows, each
    # bounded by the cell width — not the codepoint count.
    rows = Format.wrap("一二三四五六七八 tail", 12)

    assert_operator rows.length, :>, 1, "content wider than the cell width must wrap onto multiple rows"
    assert(
      rows.all? { |row| Format.display_width(row) <= 12 },
      "every wrapped row must respect the cell width, not the codepoint length"
    )
  end
end
