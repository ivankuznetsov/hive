require "test_helper"
require "hive/tui/views/format"

# Direct coverage for the public `Format.wrap` helper. Until now its
# branches (empty guard, multi-line input, the `max_width <= 8` truncate
# fallback, and the over-long-word path) were exercised only indirectly
# through overlay rendering.
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

  def test_narrow_width_falls_back_to_truncation_with_ellipsis
    # max_width <= 8 skips word-wrapping entirely and hard-truncates.
    assert_equal [ "hello w…" ], Format.wrap("hello world", 8)
  end

  def test_over_long_single_word_is_truncated_with_ellipsis
    rows = Format.wrap("supercalifragilistic", 12)

    assert_equal 1, rows.length
    assert_operator Format.display_width(rows.first), :<=, 12
    assert rows.first.end_with?("…"), "an unbreakable word wider than the width must be truncated"
  end

  def test_wide_characters_are_measured_in_cells_not_codepoints
    # Each CJK glyph is two cells wide, so four of them fill a width of 8.
    rows = Format.wrap("一二三四五六", 8)

    assert(rows.all? { |row| Format.display_width(row) <= 8 }, "wide glyphs must respect the cell width")
  end
end
