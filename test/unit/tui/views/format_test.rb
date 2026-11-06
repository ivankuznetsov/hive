require "test_helper"
require "hive/tui/views/format"

class HiveTuiViewsFormatTest < Minitest::Test
  # Hand-rolled SGR escapes rather than `Styles::CURSOR_HIGHLIGHT.render`:
  # Lipgloss strips ANSI in non-tty test environments (see styles.rb), so
  # these constants stand in for what render emits on a real terminal.
  REVERSE = "\e[7m"
  RESET = "\e[0m"

  def test_cell_chunks_wraps_cjk_by_terminal_cells_without_loss
    source = "一二三四五六七八九十"

    assert_equal [ "一二三四五", "六七八九十" ], cell_chunks(source, 10)
  end

  def test_cell_chunks_keeps_oversized_graphemes_on_separate_rows
    assert_equal [ "界" ], cell_chunks("界", 1)
    assert_equal 2, Hive::Tui::Views::Format.display_width(cell_chunks("界", 1).first)
    assert_equal [ "界", "語" ], cell_chunks("界語", 1)
    assert_equal [ "a", "界", "b" ], cell_chunks("a界b", 1)
  end

  def test_cell_chunks_preserves_mixed_and_combining_graphemes
    assert_equal [ "ab界", "c語d" ], cell_chunks("ab界c語d", 4)
    assert_equal [ "e\u0301", "界", "👩‍💻", "x" ], cell_chunks("e\u0301界👩‍💻x", 1)
    assert_equal [ "\u200Ba\u200B", "b" ], cell_chunks("\u200Ba\u200Bb", 1)
    assert_equal [ "\u200B" ], cell_chunks("\u200B", 1)
    assert_equal [ "…", "x" ], cell_chunks("…x", 1)
  end

  def test_cell_chunks_preserves_control_tokens_without_charging_cells
    source = "#{REVERSE}ab\e[2K界#{RESET}c\e"

    assert_equal [ "#{REVERSE}ab\e[2K", "界#{RESET}", "c\e" ], cell_chunks(source, 2)
    assert_equal [ "#{REVERSE}界#{RESET}\e" ], cell_chunks("#{REVERSE}界#{RESET}\e", 1)
    assert_equal [ "#{REVERSE}#{RESET}" ], cell_chunks("#{REVERSE}#{RESET}", 1)
  end

  def test_cell_chunks_coerces_inputs_and_normalizes_nonpositive_budgets
    assert_equal [ "" ], cell_chunks(nil, 3)
    assert_equal [ "" ], cell_chunks("", 3)
    assert_equal [ "1", "2" ], cell_chunks(12, 1)
    [ 0, -2 ].each do |width|
      assert_equal [ "a", "界", "b" ], cell_chunks("a界b", width)
    end
  end

  def test_cell_chunks_rejects_physical_line_breaks_after_coercion
    [ "a\nb", "a\rb", "\r\n" ].each do |source|
      label = Object.new
      label.define_singleton_method(:to_s) { source }
      assert_raises(ArgumentError) { Hive::Tui::Views::Format.cell_chunks(label, 10) }
    end
  end

  def test_character_and_word_wrappers_keep_their_existing_width_contracts
    assert_equal [ "界語", "ab" ], Hive::Tui::Views::Format.character_chunks("界語ab", 2)
    assert_equal [ "" ], Hive::Tui::Views::Format.character_chunks(nil, 2)
    assert_equal [ "one two", "three" ], Hive::Tui::Views::Format.wrap("one two three", 9)
    assert_equal [ "abc…" ], Hive::Tui::Views::Format.wrap("abcdef", 4)
  end

  # Every accepted line must reconstruct byte-for-byte, including ANSI tokens.
  def cell_chunks(source, width)
    rows = Hive::Tui::Views::Format.cell_chunks(source, width)
    assert_equal source.to_s, rows.join
    rows
  end

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

  # A wide grapheme that does not fit must end visible consumption: the
  # cut is a prefix cut, so no later text token may leak past it — even
  # when mid-line SGR sequences split the line into several text tokens.
  def test_truncate_stops_visible_consumption_at_first_non_fitting_grapheme_across_tokens
    robot = "🤖" # display width 2
    line = "#{REVERSE}a#{robot}#{REVERSE}bold#{RESET}tail#{RESET}"

    out = Hive::Tui::Views::Format.truncate(line, 3)

    assert_equal "a…", Hive::Tui::Views::Format.strip_ansi(out),
      "text after a non-fitting wide grapheme must not leak into the cut"
    assert_includes out, RESET, "any style left open by the cut must be closed"
  end

  def test_truncate_plain_text_prefix_semantics_with_wide_grapheme
    out = Hive::Tui::Views::Format.truncate("a🤖Z", 3)

    assert_equal "a…", out
  end

  def test_ljust_cells_pads_by_visible_width_for_styled_strings
    assert_equal "#{REVERSE}ab#{RESET}   ",
      Hive::Tui::Views::Format.ljust_cells("#{REVERSE}ab#{RESET}", 5)
    assert_equal "ab   ", Hive::Tui::Views::Format.ljust_cells("ab", 5)
  end
end
