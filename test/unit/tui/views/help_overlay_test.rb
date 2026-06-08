require "test_helper"
require "hive/tui/help"
require "hive/tui/model"
require "hive/tui/views/help_overlay"
require "hive/tui/views/format"

class HiveTuiViewsHelpOverlayTest < Minitest::Test
  include HiveTestHelper

  def model(cols: 80, rows: 24, help_scroll_offset: 0)
    Hive::Tui::Model.initial.with(
      mode: :help,
      cols: cols,
      rows: rows,
      help_scroll_offset: help_scroll_offset
    )
  end

  def test_renders_title_and_scroll_footer
    out = Hive::Tui::Views::HelpOverlay.render(model)
    assert_includes out, "hive tui — keybindings"
    assert_includes out, "PgUp/PgDn scroll"
    assert_includes out, "Esc/? close"
  end

  def test_full_content_includes_every_mode_header_with_bindings
    out = Hive::Tui::Views::HelpOverlay.build_lines.join("\n")
    assert_includes out, "Grid mode"
    assert_includes out, "Log tail mode"
    assert_includes out, "Filter prompt"
    assert_includes out, "Idea preview (i)"
    assert_includes out, "New-idea prompt",
                    "v2 :new_idea bindings must surface in the help overlay; without this " \
                    "header, the n / Enter / Esc bindings in :new_idea mode are invisible"
  end

  def test_full_content_includes_idea_preview_section_header
    out = Hive::Tui::Views::HelpOverlay.build_lines.join("\n")
    assert_includes out, "Idea preview (i)"
  end

  def test_full_content_includes_v2_pane_focus_and_navigation_keys
    out = Hive::Tui::Views::HelpOverlay.build_lines.join("\n")
    assert_includes out, "Tab",        "Tab pane-focus binding must be discoverable"
    assert_includes out, "Shift+Tab",  "Shift+Tab pane-focus binding must be discoverable"
    assert_includes out, "Left",       "Left pane-focus binding must be discoverable"
    assert_includes out, "Right",      "Right pane-focus binding must be discoverable"
    assert_match(/\bn\b.*new-idea/i, out, "n binding must surface with its action description")
    assert_match(/\bg\b.*top/i, out, "g (jump to top) must be discoverable")
    assert_match(/\bG\b.*bottom/i, out, "G (jump to bottom) must be discoverable")
  end

  def test_full_content_includes_grid_workflow_verb_keys
    out = Hive::Tui::Views::HelpOverlay.build_lines.join("\n")
    %w[brainstorm plan develop open-pr review finalize archive].each do |verb|
      assert_match(/#{verb}/, out, "help overlay must list #{verb}")
    end
  end

  def test_build_lines_groups_bindings_by_mode
    lines = Hive::Tui::Views::HelpOverlay.build_lines
    grid_idx = lines.index { |l| l.include?("Grid mode") }
    log_tail_idx = lines.index { |l| l.include?("Log tail mode") }
    refute_nil grid_idx
    refute_nil log_tail_idx
    assert grid_idx < log_tail_idx, "Grid section must precede Log tail section"
  end

  def test_renders_inside_a_bordered_box
    out = Hive::Tui::Views::HelpOverlay.render(model)
    # Lipgloss NORMAL border uses "─│┌┐└┘" so at least one corner char
    # should appear in the rendered output.
    assert_match(/[┌┐└┘─│]/, out, "rendered overlay must include border characters")
  end

  def test_short_terminal_windows_content_without_exceeding_height
    short = model(cols: 80, rows: 14)
    out = Hive::Tui::Views::HelpOverlay.render(short)

    assert_operator out.lines.count, :<=, short.rows
    assert_includes out, "hive tui — keybindings"
    refute_includes out, "New-idea prompt"
    assert_includes Hive::Tui::Views::HelpOverlay.content_lines(short).join("\n"), "New-idea prompt"
  end

  def test_bottom_scroll_shows_last_content_and_hides_title
    short = model(cols: 80, rows: 14)
    max = Hive::Tui::Views::HelpOverlay.max_scroll_offset(short)
    bottom = short.with(help_scroll_offset: max)
    content = Hive::Tui::Views::HelpOverlay.content_lines(bottom)
    last_line = content.last
    out = Hive::Tui::Views::HelpOverlay.render(bottom)

    assert_operator max, :>, 0
    assert_includes out, last_line
    refute_includes out, "hive tui — keybindings"
  end

  def test_overflow_renders_scrollbar_thumb
    out = Hive::Tui::Views::HelpOverlay.render(model(cols: 80, rows: 14))

    assert_includes out, "█"
  end

  def test_scrollbar_thumb_tracks_offset_to_top_and_bottom
    total = 40
    rows = 10
    top = Hive::Tui::Views::HelpOverlay.scrollbar_lines(total: total, rows: rows, offset: 0)
    bottom = Hive::Tui::Views::HelpOverlay.scrollbar_lines(total: total, rows: rows, offset: total - rows)

    assert_equal "█", top.first, "thumb must sit at the top row when not scrolled"
    refute_equal "█", top.last, "thumb must not occupy the bottom row at offset 0"
    assert_equal "█", bottom.last, "thumb must reach the bottom row at max offset"
    refute_equal "█", bottom.first, "thumb must leave the top row at max offset"
  end

  def test_scrollbar_gutter_is_blank_when_content_fits
    # total <= rows means no overflow, so the gutter must be entirely
    # blank — not a full-height `│` track. A regression that always drew
    # the track would still pass the `refute_includes "█"` overflow tests.
    assert_equal Array.new(10, " "),
                 Hive::Tui::Views::HelpOverlay.scrollbar_lines(total: 5, rows: 10, offset: 0),
                 "a non-overflowing viewport must render a blank gutter, not a track"
  end

  def test_scrollbar_thumb_size_stays_within_bounds
    lines = Hive::Tui::Views::HelpOverlay.scrollbar_lines(total: 40, rows: 10, offset: 0)
    thumb = lines.count { |cell| cell == "█" }

    assert_operator thumb, :>=, 1, "thumb must be at least one row tall"
    assert_operator thumb, :<=, 10, "thumb must never exceed the gutter height"
  end

  def test_footer_close_affordance_survives_truncation_at_min_width
    narrow = model(cols: Hive::Tui::Views::HelpOverlay::MIN_COLS, rows: Hive::Tui::Views::HelpOverlay::MIN_ROWS)
    out = Hive::Tui::Views::HelpOverlay.render(narrow)

    assert_includes out, "Esc/? close",
                    "the dismiss affordance must survive footer truncation at the minimum width"
  end

  def test_non_overflow_omits_scrollbar_thumb
    out = Hive::Tui::Views::HelpOverlay.render(model(cols: 80, rows: 200))

    refute_includes out, "█"
  end

  def test_narrow_terminal_wraps_content_and_render_lines_fit
    narrow = model(cols: 50, rows: 24)
    content = Hive::Tui::Views::HelpOverlay.content_lines(narrow)
    inner_width = Hive::Tui::Views::HelpOverlay.inner_content_width(narrow)
    out = Hive::Tui::Views::HelpOverlay.render(narrow)

    assert_operator content.length, :>, Hive::Tui::Views::HelpOverlay.build_lines.length
    assert content.all? { |line| Hive::Tui::Views::Format.display_width(line) <= inner_width }
    assert out.lines.all? { |line| Hive::Tui::Views::Format.display_width(line.chomp) <= narrow.cols }
  end

  def test_minimum_size_renders_bordered_overlay
    out = Hive::Tui::Views::HelpOverlay.render(
      model(cols: Hive::Tui::Views::HelpOverlay::MIN_COLS, rows: Hive::Tui::Views::HelpOverlay::MIN_ROWS)
    )

    assert_match(/[┌┐└┘─│]/, out, "at exactly the minimum size the bordered overlay must render")
    assert_includes out, "hive tui — keybindings"
    refute_includes out, "Terminal too small"
  end

  def test_one_column_below_minimum_falls_back
    out = Hive::Tui::Views::HelpOverlay.render(
      model(cols: Hive::Tui::Views::HelpOverlay::MIN_COLS - 1, rows: Hive::Tui::Views::HelpOverlay::MIN_ROWS)
    )

    assert_includes out, "Terminal too small",
                    "one column under MIN_COLS must trip the too-small fallback"
  end

  def test_too_small_terminal_renders_centered_fallback_without_border
    tiny = model(cols: 30, rows: 8)
    out = Hive::Tui::Views::HelpOverlay.render(tiny)

    assert_includes out, "Terminal too small"
    assert_includes out, "10×40"
    refute_match(/[┌┐└┘─│]/, out)
    assert_operator out.lines.count, :<=, tiny.rows
    assert out.lines.all? { |line| Hive::Tui::Views::Format.display_width(line.chomp) <= tiny.cols }
  end

  def test_degenerate_height_collapses_to_bare_dimension_fallback
    # rows: 1 leaves no room for the full TOO_SMALL_MESSAGE even after
    # wrapping, so render_too_small must collapse to the bare "need 10×40"
    # guidance — the exact `lines.length > height` branch the others miss.
    out = Hive::Tui::Views::HelpOverlay.render(model(cols: 30, rows: 1))

    assert_equal 1, out.lines.count, "a single-row terminal must emit exactly one line"
    assert_includes out, "need 10×40"
    refute_includes out, "Terminal too small", "the full message can't fit in one row"
  end

  def test_keybinding_rows_keep_key_column_alignment_at_wide_width
    # The cheatsheet's `%-7s` key column + 2-space indent must survive
    # wrapping verbatim on a wide terminal (no reflow when a line fits).
    # A regression that collapses internal whitespace turns "  b        run…"
    # into "b run…", destroying the column the feature exists to provide.
    lines = Hive::Tui::Views::HelpOverlay.content_lines(model(cols: 120, rows: 60))
    binding_rows = lines.select { |l| l.start_with?("  ") && l.strip.split(/\s{2,}/).length >= 2 }

    refute_empty binding_rows, "expected indented `  key      desc` rows"
    assert(binding_rows.all? { |l| l.match?(/\A {2}\S+ {2,}\S/) },
           "each binding row must keep its 2-space indent and a multi-space key/desc gap")
  end

  def test_scrollbar_thumb_sits_mid_gutter_for_mid_range_offset
    # Thumb position interpolates ((offset/max)*(rows-thumb)).round. At a
    # mid-range offset the thumb must sit strictly between the top and
    # bottom rows — pinning the interpolation so an inverted or off-by-one
    # mapping (only checked at the extremes elsewhere) fails here.
    total = 40
    rows = 10
    max_offset = total - rows
    mid = Hive::Tui::Views::HelpOverlay.scrollbar_lines(total: total, rows: rows, offset: max_offset / 2)
    first_thumb = mid.index("█")
    last_thumb = mid.rindex("█")

    assert first_thumb, "a mid-range offset must still draw a thumb"
    assert_operator first_thumb, :>, 0, "mid-range thumb must leave the top row"
    assert_operator last_thumb, :<, rows - 1, "mid-range thumb must not reach the bottom row"
  end

  def test_compact_box_does_not_pad_to_full_height_when_content_fits
    # On a tall terminal a short cheatsheet must render compact, not
    # balloon into a near-empty full-screen box padded with blank rows.
    tall = model(cols: 120, rows: 90)
    out = Hive::Tui::Views::HelpOverlay.render(tall)

    assert_operator out.lines.count, :<, tall.rows,
                    "a fitting cheatsheet must not pad the box to the full terminal height"
  end

  def test_footer_scroll_hint_truncates_at_narrow_width
    # At a width where DISMISS_HINT can't fit, the footer is truncated to
    # box_width - PADDING_COLS: the close affordance leads and survives,
    # the trailing scroll-key portion is dropped.
    narrow = model(cols: Hive::Tui::Views::HelpOverlay::MIN_COLS, rows: 24)
    out = Hive::Tui::Views::HelpOverlay.render(narrow)

    assert_includes out, "Esc/? close", "the leading close affordance must survive truncation"
    refute_includes out, "PgUp/PgDn scroll",
                     "the trailing scroll-key hint must be dropped when the footer is truncated"
  end
end
