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
  # v2 palette: blue = ready_*, magenta = agent_running, red = error/recover,
  # yellow = needs_input/review_findings, green = archived.

  def test_for_action_key_agent_running_is_magenta_foreground
    style = Hive::Tui::Styles.for_action_key("agent_running")
    assert_equal "5", style.get_foreground, "agent_running should be magenta (ANSI index 5)"
  end

  def test_for_action_key_error_is_red_foreground
    style = Hive::Tui::Styles.for_action_key("error")
    assert_equal "1", style.get_foreground, "error should be red (ANSI index 1)"
  end

  def test_for_action_key_recover_execute_is_red
    style = Hive::Tui::Styles.for_action_key("recover_execute")
    assert_equal "1", style.get_foreground
  end

  def test_for_action_key_recover_review_is_red
    style = Hive::Tui::Styles.for_action_key("recover_review")
    assert_equal "1", style.get_foreground
  end

  def test_for_action_key_needs_input_is_yellow
    style = Hive::Tui::Styles.for_action_key("needs_input")
    assert_equal "3", style.get_foreground, "needs_input should be yellow (ANSI index 3)"
  end

  def test_for_action_key_review_findings_is_yellow
    style = Hive::Tui::Styles.for_action_key("review_findings")
    assert_equal "3", style.get_foreground
  end

  def test_for_action_key_archived_is_green
    # v2 reserves green for the terminal "done" state. v1 had archived
    # default-styled; the column-status-by-color contract benefits from
    # making completion visible at a glance.
    style = Hive::Tui::Styles.for_action_key("archived")
    assert_equal "2", style.get_foreground, "archived should be green (ANSI index 2)"
  end

  def test_for_action_key_ready_to_brainstorm_is_blue
    style = Hive::Tui::Styles.for_action_key("ready_to_brainstorm")
    assert_equal "4", style.get_foreground, "any ready_* action should be blue (ANSI index 4)"
  end

  def test_for_action_key_ready_for_pr_is_blue
    style = Hive::Tui::Styles.for_action_key("ready_for_pr")
    assert_equal "4", style.get_foreground
  end

  def test_for_action_key_unknown_returns_default_style_with_no_foreground
    style = Hive::Tui::Styles.for_action_key("brand_new_thing_we_dont_know")
    # Default Style has no foreground set — Lipgloss::Style#get_foreground
    # returns nil when no foreground was applied.
    assert_nil style.get_foreground
  end


  # F23: for_action_key now returns a memoized Style instance per
  # color key. The grid renderer calls it for every visible row on
  # every frame; the per-call Style.new + foreground FFI crossing
  # was ~6000 allocations/sec at 60fps × 50 rows. Style#render is
  # read-only, so sharing is observably equivalent to the prior
  # fresh-allocation contract.
  def test_for_action_key_returns_memoized_style_per_key
    a = Hive::Tui::Styles.for_action_key("agent_running")
    b = Hive::Tui::Styles.for_action_key("agent_running")
    assert_same a, b, "for_action_key must memoize per color key after F23"
  end

  def test_for_action_key_yellow_branches_share_one_yellow_instance_or_each_have_own
    # Either all three "yellow" keys point at the SAME Style instance
    # (one shared yellow), or each has its OWN frozen instance — both
    # are acceptable memoizations. What's NOT acceptable is allocating
    # a new instance per call. Pin the latter property explicitly.
    e1 = Hive::Tui::Styles.for_action_key("error")
    e2 = Hive::Tui::Styles.for_action_key("error")
    assert_same e1, e2
  end

  def test_for_action_key_ready_branches_share_one_green_instance
    a = Hive::Tui::Styles.for_action_key("ready_to_brainstorm")
    b = Hive::Tui::Styles.for_action_key("ready_for_pr")
    assert_same a, b,
      "all ready_* keys hit the same READY_STYLE constant — one Style, one FFI cost"
  end

  def test_memoized_action_key_styles_are_frozen
    Hive::Tui::Styles::ACTION_KEY_STYLES.each_value do |style|
      assert style.frozen?, "memoized Style #{style.inspect} must be frozen"
    end
    assert Hive::Tui::Styles::READY_STYLE.frozen?
    assert Hive::Tui::Styles::DEFAULT_STYLE.frozen?
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

  def test_action_key_colors_covers_v2_additions
    # v2 widens the palette beyond v1's recovery-only mapping.
    %w[needs_input review_findings archived].each do |k|
      assert Hive::Tui::Styles::ACTION_KEY_COLORS.key?(k),
             "ACTION_KEY_COLORS must define #{k.inspect} (v2 palette)"
    end
  end

  # ---------- v2 pane border styles ----------
  # lipgloss-ruby v0.2.x doesn't expose border-foreground getters, so we
  # can't read back the configured cyan/grey accent at the C boundary.
  # The styles ARE rendered correctly in a real tty (manual dogfood per
  # the v1 strategy at docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md);
  # what we can pin in tests is constant existence, distinct instances,
  # and frozen-ness.

  def test_pane_focused_border_constant_exists
    assert_kind_of Lipgloss::Style, Hive::Tui::Styles::PANE_FOCUSED_BORDER
  end

  def test_pane_dim_border_constant_exists
    assert_kind_of Lipgloss::Style, Hive::Tui::Styles::PANE_DIM_BORDER
  end

  def test_pane_focused_and_dim_borders_are_distinct_instances
    refute_same Hive::Tui::Styles::PANE_FOCUSED_BORDER,
                Hive::Tui::Styles::PANE_DIM_BORDER,
                "focused and dim border must be distinct Style instances"
  end

  def test_pane_borders_are_frozen
    assert Hive::Tui::Styles::PANE_FOCUSED_BORDER.frozen?
    assert Hive::Tui::Styles::PANE_DIM_BORDER.frozen?
  end
end
