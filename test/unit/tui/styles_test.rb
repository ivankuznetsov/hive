require "test_helper"
require "hive/tui/styles"

# `Hive::Tui::Styles` is the central Lipgloss style factory introduced
# by U3 of the Charm migration plan. These tests pin the style state
# via Lipgloss::Style getters / predicates (get_foreground, bold?,
# reverse?, etc.) rather than rendered ANSI output — per U2 verification
# (docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md), lipgloss-ruby
# v0.2.2 strips ANSI escapes when stdout is not a tty, so render-output
# assertions are non-deterministic in CI. Style state is reachable via
# the C-extension getters regardless of tty.
class HiveTuiStylesTest < Minitest::Test
  include HiveTestHelper

  # ---------- color() symbol→string adapter ----------

  def test_color_resolves_named_ansi_symbol_to_index_string
    # Lipgloss::ANSIColor maps :cyan → "6" per the gem's ANSIColor::COLORS table.
    assert_equal "6", Hive::Tui::Styles.color(:cyan)
    assert_equal "3", Hive::Tui::Styles.color(:yellow)
    assert_equal "2", Hive::Tui::Styles.color(:green)
  end

  def test_color_passes_string_indices_through_unchanged
    assert_equal "212", Hive::Tui::Styles.color("212")
  end

  def test_color_passes_hex_string_through_unchanged
    assert_equal "#00ffff", Hive::Tui::Styles.color("#00ffff")
  end

  def test_color_raises_on_unknown_symbol
    assert_raises(ArgumentError) { Hive::Tui::Styles.color(:unobtanium) }
  end

  # ---------- for_action_key() per-row style ----------

  def test_for_action_key_agent_running_is_cyan_foreground
    style = Hive::Tui::Styles.for_action_key("agent_running")
    assert_equal "6", style.get_foreground, "agent_running should be cyan (ANSI index 6)"
  end

  def test_for_action_key_error_is_yellow_foreground
    style = Hive::Tui::Styles.for_action_key("error")
    assert_equal "3", style.get_foreground, "error should be yellow (ANSI index 3)"
  end

  def test_for_action_key_recover_execute_is_yellow
    style = Hive::Tui::Styles.for_action_key("recover_execute")
    assert_equal "3", style.get_foreground
  end

  def test_for_action_key_recover_review_is_yellow
    style = Hive::Tui::Styles.for_action_key("recover_review")
    assert_equal "3", style.get_foreground
  end

  def test_for_action_key_ready_to_brainstorm_is_green
    style = Hive::Tui::Styles.for_action_key("ready_to_brainstorm")
    assert_equal "2", style.get_foreground, "any ready_* action should be green (ANSI index 2)"
  end

  def test_for_action_key_ready_for_pr_is_green
    style = Hive::Tui::Styles.for_action_key("ready_for_pr")
    assert_equal "2", style.get_foreground
  end

  def test_for_action_key_unknown_returns_default_style_with_no_foreground
    style = Hive::Tui::Styles.for_action_key("brand_new_thing_we_dont_know")
    # Default Style has no foreground set — Lipgloss::Style#get_foreground
    # returns nil when no foreground was applied.
    assert_nil style.get_foreground
  end

  def test_for_action_key_archived_returns_default_style
    # archived rows have no special color in the curses palette either.
    style = Hive::Tui::Styles.for_action_key("archived")
    assert_nil style.get_foreground
  end

  def test_for_action_key_returns_independent_style_instances_for_chaining
    # Callers may layer additional modifiers (e.g., add_modifier(REVERSED)
    # for the cursor row) without mutating the shared palette.
    a = Hive::Tui::Styles.for_action_key("agent_running")
    b = Hive::Tui::Styles.for_action_key("agent_running")
    refute_same a, b, "for_action_key must return a fresh Style each call"
  end

  # ---------- Module-level Style constants ----------

  def test_header_style_is_bold
    assert Hive::Tui::Styles::HEADER.bold?, "HEADER must be bold for visual hierarchy"
  end

  def test_cursor_highlight_uses_reverse_video
    # Reverse video is the cursor signal that survives monochrome /
    # 16-color / TrueColor terminals consistently — chosen over a
    # foreground/background pair so it works on every terminal.
    assert Hive::Tui::Styles::CURSOR_HIGHLIGHT.reverse?,
           "CURSOR_HIGHLIGHT must use reverse video for terminal-agnostic visibility"
  end

  def test_flash_style_is_yellow_and_bold
    assert_equal "3", Hive::Tui::Styles::FLASH.get_foreground
    assert Hive::Tui::Styles::FLASH.bold?
  end

  def test_stalled_banner_is_yellow_and_reversed
    assert_equal "3", Hive::Tui::Styles::STALLED.get_foreground
    assert Hive::Tui::Styles::STALLED.reverse?
  end

  def test_hint_style_is_faint
    assert Hive::Tui::Styles::HINT.faint?,
           "HINT footer must be faint so it recedes against active grid content"
  end

  # ---------- ACTION_KEY_COLORS table ----------

  def test_action_key_colors_table_is_frozen
    assert Hive::Tui::Styles::ACTION_KEY_COLORS.frozen?,
           "ACTION_KEY_COLORS must be frozen — runtime mutation would race the renderer"
  end

  def test_action_key_colors_covers_recovery_actions
    %w[agent_running error recover_execute recover_review].each do |k|
      assert Hive::Tui::Styles::ACTION_KEY_COLORS.key?(k),
             "ACTION_KEY_COLORS must define #{k.inspect}"
    end
  end
end
