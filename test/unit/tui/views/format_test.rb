require "test_helper"
require "hive/tui/views/format"

class HiveTuiViewsFormatTest < Minitest::Test
  # Hand-rolled SGR escapes rather than `Styles::CURSOR_HIGHLIGHT.render`:
  # Lipgloss strips ANSI in non-tty test environments (see styles.rb), so
  # these constants stand in for what render emits on a real terminal.
  REVERSE = "\e[7m"
  RESET = "\e[0m"

  def test_display_width_ignores_ansi_escape_sequences
    assert_equal 3, Hive::Tui::Views::Format.display_width("#{REVERSE}abc#{RESET}")
  end

  def test_truncate_leaves_plain_strings_within_width_untouched
    assert_equal "hello", Hive::Tui::Views::Format.truncate("hello", 10)
  end

  def test_truncate_styled_line_measures_visible_cells_not_escape_bytes
    line = "#{REVERSE}> #{'a' * 40}#{RESET}"

    out = Hive::Tui::Views::Format.truncate(line, 20)

    assert_equal 20, Hive::Tui::Views::Format.display_width(out),
      "escape bytes must not consume truncation budget"
    assert_includes out, "> aaaa", "visible characters must not be cut early"
  end

  def test_truncate_preserves_trailing_reset_when_cutting_a_styled_line
    line = "#{REVERSE}> #{'a' * 40}#{RESET}"

    out = Hive::Tui::Views::Format.truncate(line, 20)

    assert_includes out, RESET,
      "the style's trailing reset must survive the cut so styling does not bleed"
  end

  def test_truncate_appends_reset_when_cut_strands_an_open_style
    # No explicit reset in the source line; the cut itself must close it.
    line = "#{REVERSE}> #{'a' * 40}"

    out = Hive::Tui::Views::Format.truncate(line, 20)

    assert_includes out, "#{RESET}…",
      "a stranded open SGR sequence must be closed by the truncator"
  end

  def test_truncate_hard_cut_path_also_closes_a_stranded_style
    line = "#{REVERSE}ab#{RESET}"

    out = Hive::Tui::Views::Format.truncate(line, 1)

    assert_equal "#{REVERSE}a#{RESET}", out
  end

  def test_ljust_cells_pads_by_visible_width_for_styled_strings
    assert_equal "#{REVERSE}ab#{RESET}   ",
      Hive::Tui::Views::Format.ljust_cells("#{REVERSE}ab#{RESET}", 5)
    assert_equal "ab   ", Hive::Tui::Views::Format.ljust_cells("ab", 5)
  end
end
